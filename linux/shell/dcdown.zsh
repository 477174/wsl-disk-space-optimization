# Docker Compose safe teardown
# Stops containers, removes locally-built images + orphan containers
# Does NOT remove volumes — all data (DBs, queues, caches) is preserved
dcdown() {
  echo "This will stop containers and remove locally-built images + orphans for this compose project."
  echo "All volumes (data) will be preserved."
  read -q "REPLY?Continue? (y/N) " || { echo "\nAborted."; return 1; }
  echo ""
  docker compose down --rmi local --remove-orphans "$@"
}
alias 'dcdown!'='docker compose down --rmi local --remove-orphans'
