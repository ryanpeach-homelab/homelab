# Vault on Synology

To generate the root password, run

```bash
pwgen -s 64 1 > root_password.txt
```

Make your vault directory

```bash
export VAULT_HOME=/volume1/docker/vault
mkdir -p $VAULT_HOME $VAULT_HOME/config $VAULT_HOME/data $VAULT_HOME/logs $VAULT_HOME/plugins
chmod -R 777 $VAULT_HOME
```
