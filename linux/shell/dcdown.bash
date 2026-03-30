# Docker Compose safe teardown (bash version)
dcdown() {
  echo "This will stop containers and remove locally-built images + orphans for this compose project."
  echo "All volumes (data) will be preserved."
  read -p "Continue? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
  docker compose down --rmi local --remove-orphans "$@"
}
alias dcdown!='docker compose down --rmi local --remove-orphans'
