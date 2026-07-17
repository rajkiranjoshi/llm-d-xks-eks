#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RBAC_DIR="${SCRIPT_DIR}/rbac"
LABEL_KEY="llmd.io/user"
USER_ROLE="llmd-user"
ADMIN_ROLE="llmd-admin"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  add <username> [--admin]   Create user namespace, SA, and bind llmd-user role
  remove <username>          Delete user namespace, SA, and all role bindings
  list                       List all managed users and their roles
  promote <username>         Grant llmd-admin (cluster-admin) role to user
  demote <username>          Revoke llmd-admin role from user
  suspend <username>         Temporarily revoke all access (preserves namespace/SA)
  resume <username>          Restore access after suspension
  kubeconfig <username>      Generate a standalone kubeconfig for the user

EOF
  exit 1
}

ensure_rbac() {
  if ! kubectl get clusterrole "$USER_ROLE" &>/dev/null; then
    echo "Applying RBAC ClusterRoles from ${RBAC_DIR}/..."
    kubectl apply -f "${RBAC_DIR}/"
  fi
}

ns_for_user() { echo "${1}-dev"; }

sa_subject() {
  local user="$1"
  echo "system:serviceaccount:$(ns_for_user "$user"):${user}"
}

cmd_add() {
  local user="${1:?Usage: $(basename "$0") add <username> [--admin]}"
  local admin=false
  [[ "${2:-}" == "--admin" ]] && admin=true

  ensure_rbac

  local ns
  ns="$(ns_for_user "$user")"

  echo "Creating namespace '${ns}'..."
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label --overwrite ns "$ns" \
    "${LABEL_KEY}=${user}" \
    "pod-security.kubernetes.io/enforce=privileged"

  echo "Creating ServiceAccount '${user}' in '${ns}'..."
  kubectl -n "$ns" create sa "$user" --dry-run=client -o yaml | kubectl apply -f -

  if ! kubectl -n "$ns" get secret "${user}-token" &>/dev/null; then
    echo "Creating long-lived token secret..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${user}-token
  namespace: ${ns}
  labels:
    ${LABEL_KEY}: "${user}"
  annotations:
    kubernetes.io/service-account.name: "${user}"
type: kubernetes.io/service-account-token
EOF
  fi

  echo "Binding ClusterRole '${USER_ROLE}' to '${user}'..."
  kubectl create clusterrolebinding "${USER_ROLE}:${user}" \
    --clusterrole="$USER_ROLE" \
    --serviceaccount="${ns}:${user}" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - "${LABEL_KEY}=${user}" -o yaml | \
    kubectl apply -f -

  if $admin; then
    cmd_promote "$user"
  fi

  echo ""
  echo "User '${user}' created."
  echo "  Namespace:  ${ns}"
  echo "  SA:         ${ns}/${user}"
  echo "  Role:       ${USER_ROLE}$( $admin && echo " + ${ADMIN_ROLE}" || true )"
  echo ""
  echo "Generate kubeconfig: $(basename "$0") kubeconfig ${user}"
}

cmd_remove() {
  local user="${1:?Usage: $(basename "$0") remove <username>}"
  local ns
  ns="$(ns_for_user "$user")"

  echo "Removing ClusterRoleBindings for '${user}'..."
  kubectl delete clusterrolebinding "${USER_ROLE}:${user}" --ignore-not-found
  kubectl delete clusterrolebinding "${ADMIN_ROLE}:${user}" --ignore-not-found

  echo "Deleting namespace '${ns}'..."
  kubectl delete ns "$ns" --ignore-not-found

  echo "User '${user}' removed."
}

cmd_list() {
  echo "Managed users:"
  echo ""
  printf "  %-20s %-12s %s\n" "USERNAME" "ROLES" "NAMESPACE"
  printf "  %-20s %-12s %s\n" "--------" "-----" "---------"

  local bindings
  bindings="$(kubectl get clusterrolebindings -l "${LABEL_KEY}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"

  # Collect unique users and their roles
  local user_users="" admin_users=""
  for binding in $bindings; do
    if [[ "$binding" == "${USER_ROLE}:"* ]]; then
      user_users="${user_users} ${binding#${USER_ROLE}:}"
    elif [[ "$binding" == "${ADMIN_ROLE}:"* ]]; then
      admin_users="${admin_users} ${binding#${ADMIN_ROLE}:}"
    fi
  done

  # Also find suspended users (they have no bindings but have labeled namespaces)
  local suspended_users=""
  suspended_users="$(kubectl get ns -l "llmd.io/suspended=true" -o jsonpath='{range .items[*]}{.metadata.labels.llmd\.io/user}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)"

  local all_combined
  all_combined="$(echo "$user_users $admin_users $suspended_users" | tr ' ' '\n' | sort -u | grep -v '^$')"

  if [[ -z "$all_combined" ]]; then
    echo "  (none)"
    return
  fi

  for user in $all_combined; do
    local roles="" suspended=false
    echo "$user_users" | grep -qw "$user" && roles="user"
    if echo "$admin_users" | grep -qw "$user"; then
      [[ -n "$roles" ]] && roles="${roles},admin" || roles="admin"
    fi
    if echo "$suspended_users" | grep -qw "$user"; then
      suspended=true
    fi
    if $suspended; then
      local prev_roles
      prev_roles="$(kubectl get ns "$(ns_for_user "$user")" -o jsonpath='{.metadata.annotations.llmd\.io/suspended-roles}' 2>/dev/null)"
      printf "  %-20s %-12s %s\n" "$user" "SUSPENDED" "$(ns_for_user "$user") (was: ${prev_roles})"
    else
      printf "  %-20s %-12s %s\n" "$user" "$roles" "$(ns_for_user "$user")"
    fi
  done
}

cmd_promote() {
  local user="${1:?Usage: $(basename "$0") promote <username>}"
  local ns
  ns="$(ns_for_user "$user")"

  if ! kubectl -n "$ns" get sa "$user" &>/dev/null; then
    echo "Error: user '${user}' not found (no SA in '${ns}')" >&2
    exit 1
  fi

  ensure_rbac

  echo "Granting ClusterRole '${ADMIN_ROLE}' to '${user}'..."
  kubectl create clusterrolebinding "${ADMIN_ROLE}:${user}" \
    --clusterrole="$ADMIN_ROLE" \
    --serviceaccount="${ns}:${user}" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - "${LABEL_KEY}=${user}" -o yaml | \
    kubectl apply -f -

  echo "User '${user}' promoted to admin."
}

cmd_demote() {
  local user="${1:?Usage: $(basename "$0") demote <username>}"

  echo "Revoking ClusterRole '${ADMIN_ROLE}' from '${user}'..."
  kubectl delete clusterrolebinding "${ADMIN_ROLE}:${user}" --ignore-not-found

  echo "User '${user}' demoted to regular user."
}

cmd_suspend() {
  local user="${1:?Usage: $(basename "$0") suspend <username>}"
  local ns
  ns="$(ns_for_user "$user")"

  if ! kubectl get ns "$ns" &>/dev/null; then
    echo "Error: namespace '${ns}' not found for user '${user}'" >&2
    exit 1
  fi

  # Determine current roles before removing bindings
  local roles=""
  kubectl get clusterrolebinding "${USER_ROLE}:${user}" &>/dev/null && roles="user"
  if kubectl get clusterrolebinding "${ADMIN_ROLE}:${user}" &>/dev/null; then
    [[ -n "$roles" ]] && roles="${roles},admin" || roles="admin"
  fi

  if [[ -z "$roles" ]]; then
    echo "User '${user}' has no active role bindings (already suspended?)."
    return
  fi

  # Store roles in annotation so resume can restore them
  kubectl annotate --overwrite ns "$ns" "llmd.io/suspended-roles=${roles}"
  kubectl label --overwrite ns "$ns" "llmd.io/suspended=true"

  echo "Removing ClusterRoleBindings for '${user}'..."
  kubectl delete clusterrolebinding "${USER_ROLE}:${user}" --ignore-not-found
  kubectl delete clusterrolebinding "${ADMIN_ROLE}:${user}" --ignore-not-found

  echo "User '${user}' suspended. Access revoked, namespace preserved."
}

cmd_resume() {
  local user="${1:?Usage: $(basename "$0") resume <username>}"
  local ns
  ns="$(ns_for_user "$user")"

  if ! kubectl get ns "$ns" &>/dev/null; then
    echo "Error: namespace '${ns}' not found for user '${user}'" >&2
    exit 1
  fi

  local roles
  roles="$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.llmd\.io/suspended-roles}' 2>/dev/null)"

  if [[ -z "$roles" ]]; then
    echo "Error: no suspension record found for '${user}'. Was the user suspended?" >&2
    exit 1
  fi

  ensure_rbac

  if [[ "$roles" == *"user"* ]]; then
    echo "Restoring ClusterRole '${USER_ROLE}' for '${user}'..."
    kubectl create clusterrolebinding "${USER_ROLE}:${user}" \
      --clusterrole="$USER_ROLE" \
      --serviceaccount="${ns}:${user}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - "${LABEL_KEY}=${user}" -o yaml | \
      kubectl apply -f -
  fi

  if [[ "$roles" == *"admin"* ]]; then
    echo "Restoring ClusterRole '${ADMIN_ROLE}' for '${user}'..."
    kubectl create clusterrolebinding "${ADMIN_ROLE}:${user}" \
      --clusterrole="$ADMIN_ROLE" \
      --serviceaccount="${ns}:${user}" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - "${LABEL_KEY}=${user}" -o yaml | \
      kubectl apply -f -
  fi

  # Clean up suspension markers
  kubectl annotate ns "$ns" "llmd.io/suspended-roles-"
  kubectl label ns "$ns" "llmd.io/suspended-"

  echo "User '${user}' resumed with roles: ${roles}."
}

cmd_kubeconfig() {
  local user="${1:?Usage: $(basename "$0") kubeconfig <username>}"
  local ns
  ns="$(ns_for_user "$user")"

  if ! kubectl -n "$ns" get secret "${user}-token" &>/dev/null; then
    echo "Error: token secret not found for '${user}' in '${ns}'" >&2
    echo "Run '$(basename "$0") add ${user}' first." >&2
    exit 1
  fi

  local token server ca_data
  # Wait briefly for the token controller to populate the secret
  for i in 1 2 3 4 5; do
    token="$(kubectl -n "$ns" get secret "${user}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)" || true
    [[ -n "$token" ]] && break
    sleep 1
  done

  if [[ -z "$token" ]]; then
    echo "Error: token not yet populated for '${user}'. Try again in a few seconds." >&2
    exit 1
  fi

  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca_data="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  local cluster_name
  cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"

  cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${cluster_name}
    cluster:
      server: ${server}
      certificate-authority-data: ${ca_data}
contexts:
  - name: ${user}@${cluster_name}
    context:
      cluster: ${cluster_name}
      user: ${user}
      namespace: ${ns}
current-context: ${user}@${cluster_name}
users:
  - name: ${user}
    user:
      token: ${token}
EOF
}

# --- Main ---
[[ $# -lt 1 ]] && usage

case "$1" in
  add)       shift; cmd_add "$@" ;;
  remove)    shift; cmd_remove "$@" ;;
  list)      shift; cmd_list "$@" ;;
  promote)   shift; cmd_promote "$@" ;;
  demote)    shift; cmd_demote "$@" ;;
  suspend)   shift; cmd_suspend "$@" ;;
  resume)    shift; cmd_resume "$@" ;;
  kubeconfig) shift; cmd_kubeconfig "$@" ;;
  *)         usage ;;
esac
