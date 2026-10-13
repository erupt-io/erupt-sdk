using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Erupt;

/// <summary>Hosting an <see cref="EruptNode"/> in ASP.NET Core.</summary>
public static class EruptNodeHosting
{
    /// <summary>
    /// Register <paramref name="node"/> with the host: it heartbeats to the erupt server once the app has started
    /// and deregisters when the app stops.
    /// </summary>
    public static IServiceCollection AddEruptNode(this IServiceCollection services, EruptNode node)
    {
        services.AddSingleton(node);
        services.AddHostedService<EruptNodeService>();
        return services;
    }

    /// <summary>Map the node's endpoints (<c>/node-health</c>, <c>/erupt-api/**</c>) into an app.</summary>
    public static IEndpointConventionBuilder MapEruptNode(this IEndpointRouteBuilder endpoints, EruptNode? node = null)
    {
        node ??= endpoints.ServiceProvider.GetRequiredService<EruptNode>();
        var group = endpoints.MapGroup("");
        group.Map("/node-health", node.HandleAsync);
        group.Map("/erupt-api/{**path}", node.HandleAsync);
        return group;
    }
}

/// <summary>Heartbeat for the lifetime of the host; deregistration on shutdown.</summary>
internal sealed class EruptNodeService(EruptNode node, IServer server, IHostApplicationLifetime lifetime, ILogger<EruptNode> logger)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        node.Logger = logger;
        // the server probes /node-health while registering, so wait until the app is listening
        var started = new TaskCompletionSource();
        await using (lifetime.ApplicationStarted.Register(() => started.TrySetResult()))
        await using (stoppingToken.Register(() => started.TrySetCanceled()))
        {
            try
            {
                await started.Task;
            }
            catch (TaskCanceledException)
            {
                return;
            }
        }
        node.ResolveAddress(ListeningPort());
        logger.LogInformation("erupt node '{Name}' at {Address} -> {Servers}", node.Options.Name, node.Options.Address, string.Join(", ", node.Options.Servers));
        await node.HeartbeatAsync(stoppingToken);
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await base.StopAsync(cancellationToken);
        if (node.Options.Address is not null) await node.DeregisterAsync();
    }

    private int ListeningPort()
    {
        foreach (var address in server.Features.Get<IServerAddressesFeature>()?.Addresses ?? [])
        {
            var port = address[(address.LastIndexOf(':') + 1)..].TrimEnd('/');
            if (int.TryParse(port, out var value)) return value;
        }
        throw new InvalidOperationException("cannot tell which port the app listens on; set NodeOptions.Address");
    }
}

public sealed partial class EruptNode
{
    /// <summary>
    /// Serve this node on its own until Ctrl+C / SIGTERM (or <paramref name="ct"/>), then deregister.
    /// <paramref name="host"/> "0.0.0.0" listens on every interface, IPv4 and IPv6.
    /// </summary>
    public async Task RunAsync(int port, string host = "0.0.0.0", CancellationToken ct = default)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.AddFilter("Microsoft", LogLevel.Warning);
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            if (host is "0.0.0.0" or "*") kestrel.ListenAnyIP(port);
            else kestrel.Listen(IPAddress.Parse(host), port);
        });
        builder.Services.AddEruptNode(this);
        var app = builder.Build();
        app.MapEruptNode(this);
        await app.RunAsync(ct);
    }
}
