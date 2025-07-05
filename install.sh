#!/bin/bash
set -e

# Define the path to your .env file
ENV_FILE="./.env"

# Define ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color - used for echo -e

# --- Terminal Cleanup Function ---
restore_terminal() {
    stty echo
    printf "\033[?25h"
    printf "\n"
}

# Trap the EXIT signal to ensure restore_terminal is always called
trap restore_terminal EXIT

# Function to print log messages with a timestamp and color
print_log() {
    local message="$1"
    local color="${2:-$WHITE}"
    echo -e "${color}$(date +"%Y-%m-%d %H:%M:%S") ${message}${NC}"
}

# Function to get a variable's current value from .env
get_env_value() {
    grep "^$1=" "$ENV_FILE" | cut -d'=' -f2-
}

# Function to prompt user for a variable value
prompt_for_variable() {
    local var_name="$1"
    local current_value="$2"
    local is_password="$3"
    local description="$4"
    local new_value=""
    local generated_value=""

    print_log "Configuring ${var_name} (${description})..." "$WHITE"

    if [[ "$is_password" == "true" ]]; then
        generated_value=$(openssl rand -base64 24)
        echo -e "${CYAN}  Default (auto-generated): ${generated_value}${NC}"
        echo -e "${CYAN}  Current in .env: ${current_value:-<not set>}${NC}"
        read -p "$(echo -e "${WHITE}  Enter new value (leave blank for auto-generated, or type 'current' to use existing): ${NC}")" new_value_input
        if [[ -z "$new_value_input" ]]; then
            new_value="$generated_value"
        elif [[ "$new_value_input" == "current" ]]; then
            new_value="$current_value"
        else
            new_value="$new_value_input"
        fi
    else
        echo -e "${CYAN}  Current in .env: ${current_value}${NC}"
        read -p "$(echo -e "${WHITE}  Enter new value (leave blank to use existing): ${NC}")" new_value_input
        if [[ -z "$new_value_input" ]]; then
            new_value="$current_value"
        else
            new_value="$new_value_input"
        fi
    fi

    if grep -q "^${var_name}=" "$ENV_FILE"; then
        sed -i.bak "s@^${var_name}=.*@${var_name}=${new_value}@" "$ENV_FILE"
    else
        echo "${var_name}=${new_value}" >> "$ENV_FILE"
    fi
    print_log "${var_name} set to: ${new_value}." "$GREEN"
    export "$var_name"="$new_value"
}


print_log "Starting n8n automated deployment script..." "$WHITE"

# --- Initial Cleanup: Ensure a clean slate before starting ---
print_log "Performing initial cleanup of any existing Docker services and volumes..." "$YELLOW"
docker compose down --volumes --remove-orphans || true
print_log "Initial cleanup complete." "$GREEN"


# --- Main Configuration Choice ---
print_log "Choose configuration method:" "$WHITE"
echo -e "${WHITE}  1) Default environment variables${NC}"
echo -e "${WHITE}  2) Custom environment variables${NC}"
read -p "$(echo -e "${YELLOW}Enter your choice (1 or 2, default is 1): ${NC}")" config_choice

config_choice=${config_choice:-1}

USE_CLOUDFLARED=false

case "$config_choice" in
    1)
        print_log "Proceeding with default environment variable generation." "$WHITE"
        N8N_ENC_KEY=$(openssl rand -base64 32)
        sed -i.bak "s@^N8N_ENCRYPTION_KEY=TOBEFILLED@N8N_ENCRYPTION_KEY=${N8N_ENC_KEY}@" "$ENV_FILE"
        print_log "Generated N8N_ENCRYPTION_KEY." "$GREEN"

        N8N_APP_DB_PASS=$(openssl rand -base64 24)
        sed -i.bak "s@^DB_POSTGRESDB_PASSWORD=new_n8n_password@DB_POSTGRESDB_PASSWORD=${N8N_APP_DB_PASS}@" "$ENV_FILE"
        print_log "Generated DB_POSTGRESDB_PASSWORD for n8n_app_user." "$GREEN"

        POSTGRES_SUPER_PASS=$(openssl rand -base64 24)
        sed -i.bak "s@^POSTGRES_PASSWORD=password123@POSTGRES_PASSWORD=${POSTGRES_SUPER_PASS}@" "$ENV_FILE"
        print_log "Generated POSTGRES_PASSWORD for postgres superuser." "$GREEN"

        REDIS_ROOT_PASS=$(openssl rand -base64 24)
        sed -i.bak "s@^REDIS_ROOT_PASSWORD=password123@REDIS_ROOT_PASSWORD=${REDIS_ROOT_PASS}@" "$ENV_FILE"
        print_log "Generated REDIS_ROOT_PASSWORD for default user." "$GREEN"

        # Ensure REDIS_PORT is set to 6379
        if grep -q "^REDIS_PORT=" "$ENV_FILE"; then
            sed -i.bak "s@^REDIS_PORT=.*@REDIS_PORT=6379@" "$ENV_FILE"
        else
            echo "REDIS_PORT=6379" >> "$ENV_FILE"
        fi
        export REDIS_PORT="6379" # Export for current script execution

        # Ensure CLOUDFLARED_TUNNEL_TOKEN is empty for localhost
        if grep -q "^CLOUDFLARED_TUNNEL_TOKEN=" "$ENV_FILE"; then
            sed -i.bak "s@^CLOUDFLARED_TUNNEL_TOKEN=.*@CLOUDFLARED_TUNNEL_TOKEN=@" "$ENV_FILE"
        else
            echo "CLOUDFLARED_TUNNEL_TOKEN=" >> "$ENV_FILE"
        fi
        print_log "Cloudflare Tunnel will be skipped for localhost deployment." "$WHITE"
        ;;
    2)
        print_log "Proceeding with custom environment variable configuration." "$WHITE"

        current_domain_name=$(get_env_value "DOMAIN_NAME")
        prompt_for_variable "DOMAIN_NAME" "$current_domain_name" "false" "the public URL for n8n"

        if [[ "$DOMAIN_NAME" == *"localhost"* ]]; then
            PROTOCOL="http"
            print_log "Setting N8N_PROTOCOL to ${PROTOCOL} for localhost." "$WHITE"
            sed -i.bak "s@^N8N_PROTOCOL=.*@N8N_PROTOCOL=${PROTOCOL}@" "$ENV_FILE"

            print_log "Cloudflare Tunnel will be skipped as DOMAIN_NAME contains 'localhost'." "$WHITE"
            if grep -q "^CLOUDFLARED_TUNNEL_TOKEN=" "$ENV_FILE"; then
                sed -i.bak "s@^CLOUDFLARED_TUNNEL_TOKEN=.*@CLOUDFLARED_TUNNEL_TOKEN=@" "$ENV_FILE"
            else
                echo "CLOUDFLARED_TUNNEL_TOKEN=" >> "$ENV_FILE"
            fi
        else
            PROTOCOL="https"
            print_log "Setting N8N_PROTOCOL to ${PROTOCOL} for custom domain." "$WHITE"
            sed -i.bak "s@^N8N_PROTOCOL=.*@N8N_PROTOCOL=${PROTOCOL}@" "$ENV_FILE"

            USE_CLOUDFLARED=true
            print_log "Custom domain detected. Cloudflare Tunnel will be enabled." "$WHITE"
            current_cf_token=$(get_env_value "CLOUDFLARED_TUNNEL_TOKEN")
            prompt_for_variable "CLOUDFLARED_TUNNEL_TOKEN" "$current_cf_token" "false" "your Cloudflare Tunnel token"
        fi

        current_n8n_enc_key=$(get_env_value "N8N_ENCRYPTION_KEY")
        prompt_for_variable "N8N_ENCRYPTION_KEY" "$current_n8n_enc_key" "true" "the encryption key for n8n credentials"

        current_n8n_db_user=$(get_env_value "DB_POSTGRESDB_USER")
        prompt_for_variable "DB_POSTGRESDB_USER" "$current_n8n_db_user" "false" "the username for n8n's PostgreSQL database"

        current_n8n_db_pass=$(get_env_value "DB_POSTGRESDB_PASSWORD")
        prompt_for_variable "DB_POSTGRESDB_PASSWORD" "$current_n8n_db_pass" "true" "the password for n8n's PostgreSQL database user"

        current_pg_user=$(get_env_value "POSTGRES_USER")
        prompt_for_variable "POSTGRES_USER" "$current_pg_user" "false" "the PostgreSQL superuser (used for initial setup)"

        current_pg_pass=$(get_env_value "POSTGRES_PASSWORD")
        prompt_for_variable "POSTGRES_PASSWORD" "$current_pg_pass" "true" "the password for the PostgreSQL superuser"

        current_redis_root_pass=$(get_env_value "REDIS_ROOT_PASSWORD")
        prompt_for_variable "REDIS_ROOT_PASSWORD" "$current_redis_root_pass" "true" "the global password for Redis"

        # Ensure REDIS_PORT is set to 6379 for custom configuration as well
        if grep -q "^REDIS_PORT=" "$ENV_FILE"; then
            sed -i.bak "s@^REDIS_PORT=.*@REDIS_PORT=6379@" "$ENV_FILE"
        else
            echo "REDIS_PORT=6379" >> "$ENV_FILE"
        fi
        export REDIS_PORT="6379" # Export for current script execution
        ;;
    *)
        print_log "Invalid option. Exiting." "$RED"
        exit 1
        ;;
esac

print_log ".env file updated with new credentials." "$GREEN"

# --- Create db/init_script.sh directory and file ---
mkdir -p db
print_log "Ensuring 'db' directory exists."

cat << 'EOF' > db/init_script.sh
#!/bin/bash
set -e;

if [ -n "${DB_POSTGRESDB_USER:-}" ] && [ -n "${DB_POSTGRESDB_PASSWORD:-}" ]; then
	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
		CREATE USER ${DB_POSTGRESDB_USER} WITH PASSWORD '${DB_POSTGRESDB_PASSWORD}';
		GRANT ALL PRIVILEGES ON DATABASE ${DB_POSTGRESDB_DATABASE} TO ${DB_POSTGRESDB_USER};
		GRANT CREATE ON SCHEMA public TO ${DB_POSTGRESDB_USER};
	EOSQL
else
	echo "SETUP INFO: DB_POSTGRESDB_USER or DB_POSTGRESDB_PASSWORD environment variables are not set. Skipping non-root user creation."
fi
EOF
chmod +x db/init_script.sh
print_log "Created and set permissions for db/init_script.sh." "$GREEN"


# --- Run Docker Compose up -d ---
print_log "Starting Docker services..." "$WHITE"
SERVICE_LIST="postgres redis n8n n8n-worker"
if $USE_CLOUDFLARED; then
    SERVICE_LIST+=" cloudflared"
fi
docker compose up -d $SERVICE_LIST

# --- Check all services health ---
print_log "Checking all services health. This may take some time..." "$YELLOW"
HEALTH_CHECK_TIMEOUT=300
START_TIME=$(date +%s)
spinner_chars="/-\|"
spinner_index=0

# Function to check health of a single service by its name from docker-compose.yml
check_health() {
    local service_name=$1
    

    local status=$(docker compose ps --format '{{.Service}}\t{{.Health}}' 2>/dev/null | \
                   awk -v s_name="$service_name" '$1 == s_name {print $2}')
    
   
    [[ "$status" == "healthy" ]]
}

# The rest of your script (SERVICE_LIST and all_healthy) remains the same as before.
# Function to check if all necessary services are healthy
all_healthy() {
    local all_ok=true

    for service in $SERVICE_LIST; do
        if ! check_health "$service"; then
            all_ok=false
            break
        fi
    done
    
    # Return the final status
    $all_ok
}


while ! all_healthy; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    spinner_char="${spinner_chars:spinner_index:1}"
    spinner_index=$(((spinner_index + 1) % ${#spinner_chars}))

    # Use printf with %b to ensure backslash escapes in variables are interpreted
    printf "\r\033[K%b%s Waiting for services to become healthy... (%s/%ss) %s%b" \
        "${YELLOW}" \
        "$(date +"%Y-%m-%d %H:%M:%S")" \
        "${ELAPSED_TIME}" \
        "${HEALTH_CHECK_TIMEOUT}" \
        "${spinner_char}" \
        "${NC}"
    
    if (( ELAPSED_TIME > HEALTH_CHECK_TIMEOUT )); then
        printf "\n"
        print_log "Error: Services did not become healthy within $HEALTH_CHECK_TIMEOUT seconds." "$RED"
        print_log "Attempting to clean up..." "$RED"
        docker compose down --volumes --remove-orphans
        print_log "Cleanup complete. Please review logs for errors." "$RED"
        exit 1
    fi
    sleep 1
done

printf "\r\033[K"
print_log "All services are healthy!" "$GREEN"


# --- Final cleanup (remove .bak files) ---
print_log "Performing final cleanup..." "$GREEN"
find . -type f -name "*.bak" -delete
print_log "Removed backup files (*.bak)." "$GREEN"

print_log "n8n deployment complete. You can access n8n at: http://${DOMAIN_NAME:-localhost:5678}" "$GREEN"
