package erupt

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---------------------------------------------------------------- server calls

func (n *Node) server() string {
	return n.cfg.Servers[int((n.next.Add(1)-1)%uint64(len(n.cfg.Servers)))]
}

func (n *Node) serverText(ctx context.Context, path string, headers map[string]string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", n.server()+path, nil)
	if err != nil {
		return "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := n.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return string(body), nil
}

// NodeConfig is the config text set for this node on the erupt server (Node Config).
func (n *Node) NodeConfig(ctx context.Context) (string, error) {
	return n.serverText(ctx, "/erupt-cloud-api/node-config/"+url.PathEscape(n.cfg.Name), map[string]string{"Access-Token": n.cfg.AccessToken})
}

// GroupConfig is the config text of this node's group on the erupt server.
func (n *Node) GroupConfig(ctx context.Context) (string, error) {
	return n.serverText(ctx, "/erupt-cloud-api/node-group-config/"+url.PathEscape(n.cfg.Name), map[string]string{"Access-Token": n.cfg.AccessToken})
}

// UserInfo is the acting user's full info from the erupt server (roles, org, post...), for the request ctx
// serves; nil when the server answers nothing.
func (n *Node) UserInfo(ctx context.Context) (M, error) {
	token, _ := ctx.Value(tokenKey{}).(string)
	text, err := n.serverText(ctx, "/erupt-cloud-api/userinfo/"+url.PathEscape(n.cfg.Name),
		map[string]string{"Access-Token": n.cfg.AccessToken, "token": token})
	if err != nil || strings.TrimSpace(text) == "" {
		return nil, err
	}
	var info M
	return info, json.Unmarshal([]byte(text), &info)
}

// post sends a form or JSON to the next server and answers its body.
func (n *Node) post(server, path, contentType string, body string) ([]byte, error) {
	resp, err := n.client.Post(server+path, contentType, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	answer, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return answer, nil
}

// errOlderServer stops the heartbeat: the server would call this node as protocol v1, which it no longer answers.
var errOlderServer = errors.New("older server")

// register announces the node once; Heartbeat repeats it. A server that does not answer it speaks protocol v2
// is an older one (PROTOCOL.md §12.2): errOlderServer.
func (n *Node) register(server, instanceID string) error {
	n.mu.RLock()
	erupts := append([]string{}, n.names...)
	n.mu.RUnlock()
	info, err := json.Marshal(M{"instanceId": instanceID, "nodeName": n.cfg.Name, "accessToken": n.cfg.AccessToken,
		"version": "go-" + Version, "protocolVersion": ProtocolVersion, "nodeAddress": []string{n.cfg.Address},
		"eruptModules": []string{}, "erupts": erupts, "resources": M{}, "capabilities": []string{"invoke"}})
	if err != nil {
		return err
	}
	answer, err := n.post(server, "/erupt-cloud-api/register-node", "application/json", string(info))
	if err != nil {
		return err
	}
	var reply struct {
		ProtocolVersion json.Number `json:"protocolVersion"`
	}
	if json.Unmarshal(answer, &reply) != nil || reply.ProtocolVersion.String() != strconv.Itoa(ProtocolVersion) {
		return errOlderServer
	}
	return nil
}

// Heartbeat registers the node every Config.Heartbeat until ctx is done. Use it when the node is mounted
// in your own server (Config.Address must then be set); ListenAndServe runs it for you. It stops for good
// when a server does not speak this SDK's node protocol: upgrade the erupt server.
func (n *Node) Heartbeat(ctx context.Context) {
	id := make([]byte, 3)
	_, _ = rand.Read(id)
	instanceID := hex.EncodeToString(id)
	failing := false
	for {
		wait := n.cfg.Heartbeat
		server := n.server()
		if err := n.register(server, instanceID); errors.Is(err, errOlderServer) {
			n.cfg.Logger.Printf("erupt: %s does not speak node protocol v%d: upgrade the erupt server; registration stopped",
				server, ProtocolVersion)
			return
		} else if err != nil {
			failing = true
			n.cfg.Logger.Printf("erupt: register failed: %v", err)
			wait /= 2
		} else if failing {
			failing = false
			n.cfg.Logger.Printf("erupt: connection success")
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// Deregister tells the server to stop routing to this instance at once.
func (n *Node) Deregister() error {
	form := url.Values{"nodeName": {n.cfg.Name}, "accessToken": {n.cfg.AccessToken}, "locations": {n.cfg.Address}}
	_, err := n.post(n.server(), "/erupt-cloud-api/remove-instance-node", "application/x-www-form-urlencoded", form.Encode())
	return err
}

// ListenAndServe serves the node on addr (e.g. ":9090"), registers it once the listener is up (the server
// probes /node-health while registering) and, on SIGINT or SIGTERM, deregisters and drains in-flight
// requests before returning.
func (n *Node) ListenAndServe(addr string) error {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	if n.cfg.Address == "" {
		port := listener.Addr().(*net.TCPAddr).Port
		// JoinHostPort brackets an IPv6 address, which a URL requires
		n.cfg.Address = "http://" + net.JoinHostPort(localIP(n.cfg.Servers[0]), strconv.Itoa(port))
	}
	n.cfg.Address = strings.TrimRight(n.cfg.Address, "/")
	srv := &http.Server{Handler: n, ReadHeaderTimeout: 10 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	served := make(chan error, 1)
	go func() { served <- srv.Serve(listener) }()
	beat, stopBeat := context.WithCancel(ctx)
	defer stopBeat()
	go n.Heartbeat(beat)
	n.cfg.Logger.Printf("erupt node '%s' at %s -> %s", n.cfg.Name, n.cfg.Address, strings.Join(n.cfg.Servers, ", "))
	select {
	case err := <-served:
		return err
	case <-ctx.Done():
	}
	stopBeat()
	if err := n.Deregister(); err != nil {
		n.cfg.Logger.Printf("erupt: deregister failed: %v", err)
	}
	drain, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return srv.Shutdown(drain)
}

// localIP is the interface address the server would see us on.
func localIP(server string) string {
	host := "127.0.0.1"
	if u, err := url.Parse(server); err == nil && u.Hostname() != "" {
		host = u.Hostname()
	}
	// prefer IPv4: "localhost" may resolve to ::1 first, and IPv4 is what servers usually reach nodes on
	conn, err := net.Dial("udp4", net.JoinHostPort(host, "80"))
	if err != nil {
		if conn, err = net.Dial("udp", net.JoinHostPort(host, "80")); err != nil {
			return "127.0.0.1"
		}
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}
