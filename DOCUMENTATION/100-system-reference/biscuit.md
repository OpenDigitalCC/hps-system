# Biscuit Token Management Library

Self-contained bash wrapper functions for managing Biscuit authentication tokens in Docker containers.

## Files

- `n_lib_biscuit.sh` - Self-contained library with all biscuit wrapper functions
- `test_n_lib_biscuit.sh` - Comprehensive test suite
- `docker-compose.yml` - Docker compose configuration for biscuit container
- `Dockerfile` - Container build configuration

## Prerequisites

- Docker
- Running biscuit container

**No external dependencies required** - the library includes built-in file-based storage.

## Storage

Configuration is stored in `/tmp/biscuit_config/` by default. You can override this by setting the `BISCUIT_CONFIG_DIR` environment variable:

```bash
export BISCUIT_CONFIG_DIR="/path/to/your/config"
```

Stored keys:
- `biscuit_private_key` - Private key
- `biscuit_public_key` - Public key
- `biscuit_ds_token` - Current token

## Container Setup

1. Build and start the biscuit container:
```bash
docker-compose up -d --build
```

2. Verify container is running:
```bash
docker ps | grep biscuit
```

## Functions Available

All functions are prefixed with `n_` and use the `biscuit` container by default.

### Container Management
- `n_verify_container [container_name]` - Verify container is running

### Keypair Management
- `n_keypair_generate [container_name]` - Generate and store keypair
- `n_keypair_get_public` - Retrieve public key
- `n_keypair_get_private` - Retrieve private key

### Token Management
- `n_token_generate [container_name]` - Generate 10-second token
- `n_token_get` - Retrieve stored token
- `n_token_inspect <token> [container_name]` - View token contents
- `n_token_verify <token> <public_key> [container_name]` - Verify token
- `n_token_attenuate <token> <datalog_check> [container_name]` - Add restrictions
- `n_token_seal <token> [container_name]` - Seal token (make final)

## Storage

All data stored in cluster_config:
- `biscuit_private_key` - Cluster private key
- `biscuit_public_key` - Cluster public key
- `biscuit_ds_token` - Current token

## Usage Examples

### Generate a keypair
```bash
source n_lib_biscuit.sh
n_keypair_generate
```

### Generate a token
```bash
token=$(n_token_generate)
echo "Generated token: $token"
```

### Verify a token
```bash
public_key=$(n_keypair_get_public)
n_token_verify "$token" "$public_key"
```

### Attenuate a token with restrictions
```bash
restricted_token=$(n_token_attenuate "$token" 'check if operation("read");')
```

### Seal a token
```bash
sealed_token=$(n_token_seal "$token")
```

## Running Tests

Simply ensure the biscuit container is running and execute:

```bash
bash test_n_lib_biscuit.sh
```

The test suite includes:
- Container verification
- Keypair generation (with overwrite protection)
- Key retrieval
- Token generation and storage
- Token inspection
- Token verification
- Token attenuation
- Token sealing
- Token expiration (10 second TTL test)

## Notes

- Tokens have a 10-second TTL (hardcoded)
- Keypair generation prompts for confirmation if keypair already exists
- All functions use `hps_log` for error/info logging
- Sealed tokens cannot be attenuated further
- Container name defaults to "biscuit" but can be overridden

## Integration with HPS

When integrating with your HPS system, you can easily adapt the storage backend:

1. Replace the `biscuit_config_*` functions to use your `cluster_config` or `host_config`
2. The rest of the library will work unchanged

Example adaptation:
```bash
biscuit_config_set() {
  cluster_config "set" "$1" "$2"
}

biscuit_config_get() {
  cluster_config "get" "$1"
}

biscuit_config_exists() {
  cluster_config "exists" "$1"
}
```
