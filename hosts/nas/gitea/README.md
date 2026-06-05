# Gitlab on Synology

To generate the root password, run

```bash
pwgen -s 64 1 > root_password.txt
pwgen -s 64 1 > db_root_password.txt
```

Make your gitlab directory

```bash
export GITEA_HOME=/volume1/docker/gitea
mkdir -p $GITEA_HOME $GITEA_HOME/data $GITEA_HOME/mysql
chmod -R 777 $GITEA_HOME
```

# Putting it all together

```bash
export GITEA_HOME=/volume1/docker/gitea
mkdir -p $GITEA_HOME $GITEA_HOME/data $GITEA_HOME/mysql
chmod -R 777 $GITEA_HOME
pwgen -s 64 1 > root_password.txt
pwgen -s 64 1 > db_root_password.txt
```
