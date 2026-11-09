# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "socket"
require "stringio"
require "uri"

module Erupt
  # The acting user of the request being served: <tt>{"uid", "account", "name", "tenantId"}</tt>.
  def self.current_user = Thread.current[:erupt_user]

  # Erupt cloud node runtime: registers with the server, then answers the requests it forwards. The wire
  # contract is erupt-cloud/PROTOCOL.md, protocol v2 (§12): the server signs every call, enforces the user's
  # rights and the model's, checks and normalizes queries and records, and turns drills and link trees into
  # conditions; the node stores and reads rows and runs its own code. A node is a Rack application
  # (+call(env)+), so it can be mounted in Rails / Sinatra / any Rack server, or served on its own with +serve+.
  class Node
    # The node protocol this SDK speaks (PROTOCOL.md §12.2)
    PROTOCOL_VERSION = 2
    # Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
    UNSUPPORTED_POWER = { "print" => false, "ai" => false }.freeze
    # A guard of the node's own: the server checks a page size too, but no call should make a node read without end
    MAX_PAGE_SIZE = 1000
    # Operators a condition may carry: like a field name, checked whoever calls (§12.6)
    OPS = %w[EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL].freeze

    POWER, QUERY, RECORD = %w[power].freeze, %w[power query].freeze, %w[power record].freeze
    # verb, path, endpoint, what the server must vouch for in Erupt-Enforced (§12.2)
    ROUTES = [
      ["GET", %r{\A/erupt-api/build/([^/]+)\z}, :build, [].freeze],
      ["POST", %r{\A/erupt-api/data/table/([^/]+)\z}, :table, QUERY],
      ["GET", %r{\A/erupt-api/data/init-value/([^/]+)\z}, :init_value, POWER],
      ["GET", %r{\A/erupt-api/data/([^/]+)/([^/]+)\z}, :get, POWER],
      ["POST", %r{\A/erupt-api/data/modify/([^/]+)\z}, :add, RECORD],
      ["POST", %r{\A/erupt-api/data/modify/([^/]+)/update\z}, :update, RECORD],
      ["POST", %r{\A/erupt-api/data/modify/([^/]+)/delete\z}, :delete, POWER],
      ["POST", %r{\A/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)\z}, :invoke, POWER]
    ].freeze
    # invoke kind -> the Field attribute holding its code
    INVOKED = { "options" => :fetch, "onchange" => :onchange, "autocomplete" => :complete, "button" => :click }.freeze

    # Answered with a bare status
    class Reply < StandardError
      attr_reader :status

      def initialize(status)
        super(status.to_s)
        @status = status
      end
    end

    # Logs to $stderr unless a logger (Rails.logger, Logger.new(...)) is given.
    class StderrLog
      %i[info warn error].each { |level| define_method(level) { |msg| $stderr.puts("[erupt] #{level.upcase} #{msg}") } }
      def debug(_msg) = nil
    end

    attr_reader :name, :address, :models

    # +access_token+ is the key the server signs every call with (PROTOCOL.md §4.3).
    def initialize(name, access_token, servers, address: nil, heartbeat: 15, logger: nil)
      raise ArgumentError, "access_token is required" if access_token.to_s.empty?

      @name, @access_token = name, access_token
      @servers = Array(servers).map { |s| s.chomp("/") }
      @address, @heartbeat, @log = address, heartbeat, logger || StderrLog.new
      @models = {}
      @tick = 0
    end

    def register(cls, repository)
      model = cls.respond_to?(:erupt_model) ? cls.erupt_model : raise(ArgumentError, "#{cls} does not extend Erupt::Model")
      model.validate!
      raise ArgumentError, "erupt '#{model.name}' registered twice" if @models.key?(model.name)
      raise ArgumentError, "#{model.name} has no primary key; only an operation form may omit it" if model.pk.nil?

      repository.bind(model)
      @models[model.name] = [model, repository]
      self
    end

    # ---------------------------------------------------------------- Rack

    def call(env)
      status, body = begin
        dispatch(env)
      rescue Reply => e
        [e.status, ""]
      rescue Fail => e
        [200, r(success: false, message: e.message)]
      rescue StandardError => e # never leak internals: message only, the stack stays in the node log
        @log.error("erupt node error: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
        [500, { "path" => env["PATH_INFO"], "status" => 500, "error" => "erupt exception", "message" => e.message }]
      ensure
        Thread.current[:erupt_user] = Thread.current[:erupt_token] = nil
      end
      payload, type = body.is_a?(String) ? [body, "text/plain; charset=utf-8"] : [JSON.generate(body), "application/json; charset=utf-8"]
      [status, { "content-type" => type, "content-length" => payload.bytesize.to_s }, [payload]]
    end

    # Serve until SIGINT / SIGTERM: HTTP first (the server probes /node-health while registering), then the
    # heartbeat; deregisters on the way out. Mount the node in a Rack server instead and call +start+ / +stop+.
    def serve(host: "0.0.0.0", port: 9090)
      http = HttpServer.new(self, host, port)
      start(port: port)
      http.run
    rescue SignalException
      nil
    ensure
      stop
      http&.close
    end

    # Start registering (and the heartbeat) for a node served by a Rack server listening on +port+.
    def start(port:)
      @instance_id = SecureRandom.hex(3)
      @address = (@address || "http://#{local_ip(@servers.first)}:#{port}").chomp("/")
      @heartbeat_thread = Thread.new { heartbeat_loop }
      @log.info("erupt node '#{@name}' at #{@address} -> #{@servers.join(", ")}")
      self
    end

    # Stop the heartbeat and deregister.
    def stop
      return unless @heartbeat_thread

      @heartbeat_thread.kill
      @heartbeat_thread = nil
      deregister
    end

    # The config text set for this node on the erupt server (Node Config).
    def config = server_call(:get, "/erupt-cloud-api/node-config/#{@name}", headers: { "Access-Token" => @access_token }, parse: false)

    # The config text of this node's group on the erupt server.
    def group_config = server_call(:get, "/erupt-cloud-api/node-group-config/#{@name}", headers: { "Access-Token" => @access_token }, parse: false)

    # The acting user's full info from the erupt server (roles, org, post...), for the request being served.
    def user_info
      headers = { "Access-Token" => @access_token, "token" => Thread.current[:erupt_token].to_s }
      text = server_call(:get, "/erupt-cloud-api/userinfo/#{@name}", headers: headers, parse: false)
      text.to_s.empty? ? nil : JSON.parse(text)
    end

    private

    def dispatch(env)
      path, method = env["PATH_INFO"].to_s, env["REQUEST_METHOD"]
      return [200, @name] if path == "/node-health"
      raise Reply, 404 unless path.start_with?("/erupt-api/")
      # server-to-server only: an Origin header means a browser reached the node directly
      raise Reply, 403 unless env["HTTP_ORIGIN"].to_s.empty?

      enforced = authenticate(env)
      ROUTES.each do |verb, pattern, handler, required|
        match = verb == method && pattern.match(path)
        next unless match
        # what lets the node skip the checks the server made: never the negotiation alone (§12.2)
        raise Reply, 403 unless (required - enforced).empty?

        name = unescape(match[1])
        raise Reply, 404 if env["HTTP_ERUPT"] != name || !@models.key?(name)

        parent = env["HTTP_ERUPTPARENT"] || query_param(env, "_eruptParent")
        # nesting is not supported yet, so a parent can only vouch for itself
        raise Reply, 404 if parent && !parent.empty? && parent[/[^.]*\z/] != name

        user = env["HTTP_USER"].to_s
        Thread.current[:erupt_user] = user.empty? ? nil : JSON.parse(user.unpack1("m"))
        Thread.current[:erupt_token] = env["HTTP_TOKEN"]
        model, repo = @models[name]
        return [200, send(handler, model, repo, env, *match.captures.drop(1).map { |g| unescape(g) })]
      end
      raise Reply, 404
    end

    # Every call is signed (§12.2); its Erupt-Enforced is what the server vouches for.
    def authenticate(env)
      signature = env["HTTP_ERUPT_SIGNATURE"] or raise Reply, 403
      enforced = env["HTTP_ERUPT_ENFORCED"]
      multipart = env["CONTENT_TYPE"].to_s.include?("multipart/form-data")
      ok = Signature.verify(@access_token, env["REQUEST_METHOD"], path_and_query(env), env["HTTP_ERUPT_TIMESTAMP"], enforced,
                            env["HTTP_USER"], multipart ? nil : body(env), signature, Time.now.to_i)
      raise Reply, 403 unless ok

      enforced.to_s.split(",").reject(&:empty?)
    end

    # ---------------------------------------------------------------- endpoints

    # the rights the model switches off, and the features this SDK does not serve yet (§12.3)
    def build(model, _repo, _env) = model.build_model(model.power.merge(UNSUPPORTED_POWER), Erupt.current_user)

    def table(model, repo, env) = page(model, repo, read_object(env))

    def page(model, repo, body)
      page_index = [int(body["pageIndex"] || 1), 1].max
      page_size = int(body["pageSize"] || 10).clamp(1, MAX_PAGE_SIZE)
      query = Query.new(offset: (page_index - 1) * page_size, limit: page_size)
      # checked and normalized by the server, a drill's join and a link tree's keys among them (§12.4)
      Array(body["condition"]).each { |c| query.conditions.concat(conditions(model, c)) }
      Array(body["sort"]).each do |s|
        # "field.column" sorts by a reference's label: the server resolves labels, the node orders by the key
        f = s.is_a?(Hash) && model.fields[s["field"].to_s.split(".").first]
        raise Fail, "illegal sort field '#{s["field"] if s.is_a?(Hash)}'" unless f

        query.sort << [f.name, s["direction"].to_s.upcase == "DESC"]
      end
      # a @Vis view's own filter and order, a drill's linkCondition, then the DataProxy's
      filters, sort = model.vis.fetch(body["vis"], [[], []])
      query.sort = (sort.empty? ? model.order : sort).dup if query.sort.empty?
      query.filters = drill(model, body) + filters + model.filters(query.conditions)
      total, records = repo.page(query)
      list = rows(model, records)
      model.hook(:after_fetch, list)
      { "pageIndex" => page_index, "pageSize" => page_size, "total" => total, "totalPage" => (total + page_size - 1) / page_size,
        "list" => list, "sort" => nil, "alert" => nil, "extraContent" => nil }
    end

    # A drilled table (§12.4): the server sent the join as a condition and names the drill, whose linkCondition the
    # node adds. The source model must be registered and declare that drill into this one.
    def drill(model, body)
      drill = body["drill"]
      return [] if drill.nil?

      source = (@models[drill["erupt"].to_s] if drill.is_a?(Hash))&.first
      erupt, condition = source&.drills&.[](drill["code"])
      raise Reply, 403 if erupt != model.name

      condition.empty? ? [] : [[condition, []]]
    end

    def conditions(model, c)
      c = {} unless c.is_a?(Hash)
      # a name the node puts into a query is one of its stored fields, whoever sends it (§12.6)
      f = model.fields[c["key"]]
      raise Fail, "illegal search field '#{c["key"]}'" if f.nil?

      op, value = c["expression"], c["value"]
      raise Fail, "illegal operator '#{op}'" unless OPS.include?(op)
      if f.json? && %w[EQ IN NEQ NOT_IN].include?(op)
        # a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
        like = %w[EQ IN].include?(op) ? "LIKE" : "NOT_LIKE"
        return (value.is_a?(Array) ? value : [value]).map { |v| Cond.new(f.name, like, JSON.generate(v.to_s)) }
      end

      # values arrive as the JSON type their field stores; dates become the repository's Date / Time
      [case op
       when "NULL", "NOT_NULL" then Cond.new(f.name, op)
       when "LIKE", "NOT_LIKE" then Cond.new(f.name, op, value.to_s)
       when "RANGE", "IN", "NOT_IN" then Cond.new(f.name, op, Array(value).map { |v| coerce(f, v) })
       else Cond.new(f.name, op, coerce(f, value))
       end]
    end

    def init_value(model, _repo, _env)
      record = model.fields.keys.to_h { |name| [name, nil] }
      model.hook(:add_behavior, record)
      rows(model, [record]).first
    end

    def get(model, repo, _env, pk)
      record = repo.get(pk_of(model, pk)) or raise Fail, "record not found"
      model.hook(:edit_behavior, record)
      rows(model, [record]).first
    end

    def add(model, repo, env)
      rec = record(model, read_object(env))
      model.hook(:validate, rec)
      model.hook(:before_add, rec)
      repo.add(rec)
      model.hook(:after_add, rec)
      r
    end

    def update(model, repo, env)
      body = read_object(env)
      pk = pk_of(model, body[model.pk])
      raise Fail, "record not found" if repo.get(pk).nil?

      rec = record(model, body)
      model.hook(:validate, rec)
      model.hook(:before_update, rec)
      repo.update(pk, rec)
      model.hook(:after_update, rec)
      r
    end

    def delete(model, repo, env)
      ids = read_json(env)
      raise Fail, "a list of ids is required" unless ids.is_a?(Array)

      pks = ids.map { |pk| pk_of(model, pk) }
      # the hooks see each record as it was; reading them costs nothing without a proxy
      records = model.proxies.empty? ? [] : pks.filter_map { |pk| repo.get(pk) }
      records.each { |rec| model.hook(:before_delete, rec) }
      repo.delete(pks)
      records.each { |rec| model.hook(:after_delete, rec) }
      r
    end

    # The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the operation
    # code, or a field's fetched options, onchange, auto-complete or button, with the form's values.
    def invoke(model, repo, env, kind, name)
      return operation(model, repo, env, name) if kind == "operation"
      return r(data: operation_form_value(model, name)) if kind == "operation-form"

      f = model.declared.find { |d| d.name == name }
      fn = f && INVOKED.key?(kind) && f.public_send(INVOKED[kind])
      raise Reply, 404 unless fn

      body = read_object(env)
      form = body["form"].is_a?(Hash) ? body["form"] : {}
      return r(data: fn.call(form, body["value"] || "").to_a) if kind == "autocomplete"

      answer = fn.call(form)
      # {value => label} or [[value, label]], as the choices of a field
      answer = answer.to_a.map { |v, label| { "value" => v.to_s, "label" => label } } if kind == "options" && f.type != EditType::TAGS
      r(data: answer)
    end

    # Records to browser rows. A reference stays its key: the server resolves its label, the flattened
    # <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3).
    def rows(model, records)
      records.map do |rec|
        model.fields.keys.to_h { |name| [name, Erupt.json_value(rec.key?(name) ? rec[name] : rec[name.to_sym])] }
      end
    end

    def operation_of(model, code)
      op = model.operations[code]
      raise Reply, 404 if op.nil?
      # a hidden operation does not exist for this user, exactly like the Java proxy filters it out
      raise Reply, 403 unless op.visible?(Erupt.current_user)

      op
    end

    def operation_form_value(model, code)
      op = operation_of(model, code)
      # none without a form: the server answers the browser a 404, and it opens an empty one
      op.form_model.fields.keys.to_h { |name| [name, nil] } if op.form
    end

    def operation(model, repo, env, code)
      op = operation_of(model, code)
      body = read_object(env)
      param = op.form && record(op.form_model, body["param"].is_a?(Hash) ? body["param"] : {})
      selected = []
      unless op.mode == RowOperationMode::BUTTON
        ids = body["ids"]
        raise Fail, "select at least one row" unless ids.is_a?(Array) && !ids.empty?
        raise Fail, "select exactly one row" if op.mode == RowOperationMode::SINGLE && ids.size != 1

        selected = ids.map { |pk| repo.get(pk_of(model, pk)) || raise(Fail, "record '#{pk}' not found") }
      end
      result = op.handler.call(OperationContext.new(rows: selected, param: param, repo: repo, model: model, user: Erupt.current_user))
      result.is_a?(String) && !result.empty? ? r(data: result) : r(message: "Executed successfully")
    end

    def pk_of(model, value) = coerce(model.fields[model.pk], value)

    def coerce(field, value)
      field.coerce(value)
    rescue ArgumentError, TypeError => e
      raise Fail, e.message
    end

    # A record the server checked and normalized (§12.4), as the repository stores it.
    def record(model, body)
      model.fields.each_value.reject { |f| f.pk? || !f.form? }.to_h do |f|
        [f.name, f.coerce(body[f.name])]
      rescue ArgumentError, TypeError => e
        raise Fail, "#{f.title}: #{e.message}"
      end
    end

    def r(success: true, message: nil, data: nil)
      { "success" => success, "status" => success ? "SUCCESS" : "ERROR", "message" => message, "data" => data, "promptWay" => "MESSAGE" }
    end

    # ---------------------------------------------------------------- server calls

    def next_server = @servers[(@tick += 1) % @servers.size]

    # GET with a query (JSON answer, or the text without +parse+), or POST a JSON / form body; raises unless the server answers 2xx.
    def server_call(method, path, server: next_server, query: nil, json: nil, form: nil, headers: {}, timeout: 5, parse: true)
      uri = URI(server + path)
      uri.query = URI.encode_www_form(query) if query
      request = method == :get ? Net::HTTP::Get.new(uri, headers) : Net::HTTP::Post.new(uri, headers)
      if json
        request.body = JSON.generate(json)
        request["Content-Type"] = "application/json"
      end
      request.set_form_data(form) if form
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |http|
        http.request(request)
      end
      raise "#{uri.path} answered HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      return response.body.to_s.dup.force_encoding(Encoding::UTF_8) unless parse

      response.body.to_s.empty? ? nil : JSON.parse(response.body)
    end

    def node_info
      { "instanceId" => @instance_id, "nodeName" => @name, "accessToken" => @access_token, "version" => "ruby-#{VERSION}",
        "protocolVersion" => PROTOCOL_VERSION, "nodeAddress" => [@address], "eruptModules" => [], "erupts" => @models.keys, "resources" => {},
        "capabilities" => ["invoke"] }
    end

    def heartbeat_loop
      failing = false
      loop do
        server = next_server
        begin
          answer = server_call(:post, "/erupt-cloud-api/register-node", server: server, json: node_info, timeout: 10, parse: false)
          unless speaks_v2?(answer)
            # an older server: it would call this node as v1, which it no longer answers (§12.2)
            @log.error("#{server} does not speak node protocol v#{PROTOCOL_VERSION}: upgrade the erupt server; registration stopped")
            return
          end
          @log.info("#{server} -> connection success") if failing
          failing = false
          sleep(@heartbeat)
        rescue StandardError => e
          failing = true
          @log.error("#{server} -> register failed: #{e.message}")
          sleep(@heartbeat / 2.0)
        end
      end
    end

    # Whether a register answer comes from a server that speaks this node's protocol (§12.2).
    def speaks_v2?(answer)
      reply = JSON.parse(answer.to_s)
      reply.is_a?(Hash) && reply["protocolVersion"] == PROTOCOL_VERSION
    rescue JSON::ParserError
      false
    end

    def deregister
      server_call(:post, "/erupt-cloud-api/remove-instance-node", form: { nodeName: @name, accessToken: @access_token, locations: @address })
    rescue StandardError => e
      @log.error("deregister failed: #{e.message}")
    end

    def read_object(env)
      body = read_json(env)
      return {} if body.nil?
      raise Fail, "a JSON object is required" unless body.is_a?(Hash)

      body
    end

    def read_json(env)
      text = body(env)
      text.empty? ? nil : JSON.parse(text.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError
      raise Fail, "malformed JSON body"
    end

    # The raw body, read once.
    def body(env)
      env["erupt.body"] ||= begin
        input = env["rack.input"]
        input&.rewind if input.respond_to?(:rewind)
        input&.read.to_s.b
      end
    end

    def int(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise Fail, "illegal number '#{value}'"
    end

    # The request target as the server signed it: the raw path below the mount point, plus the query.
    def path_and_query(env)
      query = env["QUERY_STRING"].to_s
      env["PATH_INFO"].to_s + (query.empty? ? "" : "?#{query}")
    end

    def unescape(text) = text.b.gsub(/%(\h\h)/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)

    def query_param(env, name)
      URI.decode_www_form(env["QUERY_STRING"].to_s).assoc(name)&.last
    rescue ArgumentError
      nil
    end

    # The interface address the server would see us on.
    def local_ip(server)
      UDPSocket.open do |s|
        s.connect(URI(server).host || "127.0.0.1", 80)
        s.addr.last
      end
    rescue StandardError
      "127.0.0.1"
    end
  end
end
