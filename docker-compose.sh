#!/bin/bash
# Unix counterpart of docker-compose.ps1. Commands: up | down | restart | logs | url
cd "$(dirname "$0")"

# Load config.env (KEY=value, '#' comments) into the environment.
if [ -f config.env ]; then
    set -a
    # shellcheck disable=SC1091
    . <(grep -E '^[^#]+=' config.env)
    set +a
fi

# Selects the tailscale serve config that docker-compose.yml mounts. Anything
# other than an explicit truthy PUBLIC_ACCESS stays tailnet-only, so a typo can
# only ever fail closed.
case "$(printf '%s' "${PUBLIC_ACCESS:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1|true|yes|on) IS_PUBLIC=1; export TS_SERVE_FILE=funnel.json ;;
    *)             IS_PUBLIC=0; export TS_SERVE_FILE=serve.json ;;
esac

# Prints the tailnet HTTPS URL to point Stremio at, read live from the node.
show_url() {
    local dns
    dns=$(docker compose exec -T tailscale tailscale status --json 2>/dev/null \
        | grep -o '"DNSName":"[^"]*"' | head -1 | sed 's/.*:"//; s/"//; s/\.$//')
    if [ -z "$dns" ]; then
        echo "Node not authenticated yet — check 'logs'." >&2; return 1
    fi
    echo
    if [ "$IS_PUBLIC" = "1" ]; then
        echo "  Public streaming server URL — share this with friends:"
        echo "      https://$dns/"
        echo "      Reachable from the open internet, with no login. Anyone who"
        echo "      has the URL can stream and download through your connection."
    else
        echo "  Streaming server URL (set this in web.stremio.com -> Settings):"
        echo "      https://$dns/"
    fi
}

case "${1:-up}" in
    up)
        # The auth key is only needed for the FIRST join; after that the node
        # identity lives in data/tailscale and the key can be blanked out.
        if [ -z "${TS_AUTHKEY:-}" ] \
            && [ ! -f data/tailscale/tailscaled.state ] \
            && [ ! -d data/tailscale/profile-data ]; then
            echo "TS_AUTHKEY is empty in config.env and this node hasn't joined yet." >&2
            echo "Create a key at https://login.tailscale.com/admin/settings/keys" >&2
            exit 1
        fi
        [ "$IS_PUBLIC" = "1" ] && echo "PUBLIC_ACCESS is on — serving over Tailscale Funnel."
        echo "Starting stremio + tailscale..."
        docker compose up -d
        echo "Waiting for the tailnet node to authenticate..."
        sleep 5
        show_url
        ;;
    down)    echo "Stopping everything..."; docker compose down ;;
    restart) echo "Recreating..."; docker compose up -d --force-recreate; show_url ;;
    logs)    docker compose logs -f ;;
    url)     show_url ;;
    *)
        echo "Usage: ./docker-compose.sh [up|down|restart|logs|url]"
        echo "  up       Start the stack (default)"
        echo "  down     Stop and remove everything"
        echo "  restart  Recreate the stack"
        echo "  logs     Follow logs"
        echo "  url      Print the HTTPS URL to use in web.stremio.com"
        exit 1
        ;;
esac
