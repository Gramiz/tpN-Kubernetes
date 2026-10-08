#!/usr/bin/env bash
# Prérequis : Java 21+, Docker avec Compose, Minikube, kubectl, curl et jq.
# ./verifier-tp.sh --complet : vérifie aussi les pannes et la perte des données.
# --profil NOM permet de choisir le profil Minikube (défaut : cinek8s-tp).
set -Eeuo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

PROFILE=cinek8s-tp
FULL=0
PASS=0
LOCAL_MOVIE_PID=''
LOCAL_TICKET_PID=''
FORWARD_PID=''
COMPOSE_ACTIVE=0
RESTORE_CLUSTER=0
DEBUG_ACTIVE=0
CHECK_TMP=''
COMPOSE_PROJECT="cinek8s-check-$$"

usage() {
  cat <<'HELP'
Usage : ./verifier-tp.sh [--complet] [--profil NOM]

Sans option : tests Maven, API locales, Docker Compose, Kubernetes, Ingress
et vérification du securityContext de movie.
--complet : ajoute l'arrêt de movie, les 3 erreurs du Deployment de dépannage,
           la modification de ConfigMap, la perte des réservations en mémoire,
           le remplacement d'un Pod et 300 requêtes pendant un rolling update.
--profil NOM : profil Minikube utilisé (par défaut : cinek8s-tp).

Ports locaux nécessaires : 8080, 8082 et 18080.
L'Ingress est testé avec cinema.local sur 18080, sans sudo ni /etc/hosts.
Les pannes concernent uniquement cinema-exam dans le profil choisi.
Avec --complet, les réservations de ce namespace sont supprimées.
Les sources restent inchangées. Le cluster est conservé pour inspection.
HELP
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --complet) FULL=1; shift ;;
    --profil) [ "$#" -ge 2 ] || { usage; exit 2; }; PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Option inconnue : %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$PROFILE" ] || { printf 'Le profil ne peut pas être vide.\n' >&2; exit 2; }

fail() { printf '\nECHEC : %s\n' "$*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'OK : %s\n' "$*"; }
step() { printf '\n--- %s ---\n' "$*"; }
k() { kubectl --context="$PROFILE" -n cinema-exam "$@"; }
compose() { docker compose -p "$COMPOSE_PROJECT" "$@"; }
stop_local() {
  for pid in "$LOCAL_MOVIE_PID" "$LOCAL_TICKET_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  LOCAL_MOVIE_PID=''; LOCAL_TICKET_PID=''
}
cleanup() {
  result=$1
  trap - EXIT ERR INT TERM
  set +e
  stop_local
  if [ -n "$FORWARD_PID" ]; then kill "$FORWARD_PID" 2>/dev/null; wait "$FORWARD_PID" 2>/dev/null; fi
  if [ "$DEBUG_ACTIVE" -eq 1 ]; then k delete deploy ticket-debug --ignore-not-found >/dev/null; fi
  if [ "$RESTORE_CLUSTER" -eq 1 ]; then
    kubectl --context="$PROFILE" apply -f k8s/ >/dev/null
    k rollout restart deploy/movie >/dev/null
  fi
  if [ "$COMPOSE_ACTIVE" -eq 1 ]; then compose down >/dev/null 2>&1; fi
  if [ -n "$CHECK_TMP" ]; then
    if [ "$result" -eq 0 ]; then rm -rf "$CHECK_TMP";
    else printf 'Logs pour le diagnostic : %s\n' "$CHECK_TMP" >&2; fi
  fi
  exit "$result"
}
trap 'cleanup $?' EXIT
trap 'printf "Erreur à la ligne %s.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

request() {
  # Corps dans un fichier temporaire, statut HTTP dans CODE.
  CODE=$(curl --max-time 10 -sS -o "$CHECK_TMP/body.json" -w '%{http_code}' "$@")
}
http() {
  expected=$1; shift
  request "$@"
  [ "$CODE" = "$expected" ] || { cat "$CHECK_TMP/body.json" >&2; fail "HTTP $CODE au lieu de $expected : $*"; }
}
json() { jq -e "$1" "$CHECK_TMP/body.json" >/dev/null || fail "JSON inattendu : $1"; }
ingress() {
  http "$1" --resolve cinema.local:18080:127.0.0.1 "http://cinema.local:18080$2" "${@:3}"
}
wait_http() {
  url=$1
  for attempt in $(seq 1 120); do
    if curl --max-time 2 -fsS "$url" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  fail "Démarrage trop long : $url"
}
wait_ingress() {
  path=$1
  for attempt in $(seq 1 60); do
    if curl --max-time 3 --resolve cinema.local:18080:127.0.0.1 -fsS "http://cinema.local:18080$path" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  fail "Ingress indisponible : $path"
}
ready() {
  k rollout status "deploy/$1" --timeout=180s
  k wait --for=condition=Available "deploy/$1" --timeout=180s
}

step 'Prérequis'
for tool in java docker minikube kubectl curl jq; do
  command -v "$tool" >/dev/null || fail "Outil manquant : $tool"
done
version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2; exit}')
major=${version%%.*}
case "$major" in ''|*[!0-9]*) fail "Version Java non reconnue : $version" ;; esac
[ "$major" -ge 21 ] || fail "Java 21 minimum requis (version actuelle : $version)"
docker info >/dev/null 2>&1 || fail 'Docker ne répond pas. Démarrer Docker Desktop ou le daemon Docker.'
docker compose version >/dev/null
CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cinek8s-check.XXXXXX")
# L'identifiant du profil n'est jamais interpolé dans une commande shell.
ok "Java $version, Docker et outils disponibles"

step 'Partie 2 : compilation et tests Maven'
(cd movie-service && ./mvnw -q package) >"$CHECK_TMP/movie-build.log" 2>&1 || { tail -40 "$CHECK_TMP/movie-build.log"; fail 'Compilation/tests movie'; }
(cd ticket-service && ./mvnw -q package) >"$CHECK_TMP/ticket-build.log" 2>&1 || { tail -40 "$CHECK_TMP/ticket-build.log"; fail 'Compilation/tests ticket'; }
ok 'Tests Maven des deux services'
SERVER_PORT=8080 java -jar movie-service/target/movie-service-1.0.0.jar >"$CHECK_TMP/movie-local.log" 2>&1 &
LOCAL_MOVIE_PID=$!
SERVER_PORT=8082 MOVIE_URL=http://localhost:8080 java -jar ticket-service/target/ticket-service-1.0.0.jar >"$CHECK_TMP/ticket-local.log" 2>&1 &
LOCAL_TICKET_PID=$!
wait_http http://localhost:8080/actuator/health/liveness
wait_http http://localhost:8082/actuator/health/liveness
kill -0 "$LOCAL_MOVIE_PID" "$LOCAL_TICKET_PID" || fail 'Ports locaux occupés ou processus Java arrêté'
http 200 http://localhost:8080/api/movies/whoami; json '.environment == "local"'
http 201 http://localhost:8082/api/tickets -H 'Content-Type: application/json' -d '{"movieId":2,"seats":3}'; json '.total == 36'
http 200 http://localhost:8082/actuator/health/readiness; json '.status == "UP" and .components.movie.status == "UP"'
ok 'API locales : réservation 36.00 et readiness UP'
kill "$LOCAL_MOVIE_PID"; wait "$LOCAL_MOVIE_PID" 2>/dev/null || true; LOCAL_MOVIE_PID=''
http 503 http://localhost:8082/actuator/health/readiness; json '.status == "DOWN"'
http 200 http://localhost:8082/actuator/health/liveness; json '.status == "UP"'
http 503 http://localhost:8082/api/tickets -H 'Content-Type: application/json' -d '{"movieId":2,"seats":3}'
ok 'Movie arrêté : readiness DOWN, liveness UP, réservation 503'
stop_local

step 'Partie 3 : Docker et Compose'
compose config --quiet
COMPOSE_ACTIVE=1
compose up -d --build >"$CHECK_TMP/compose.log" 2>&1 || { tail -40 "$CHECK_TMP/compose.log"; fail 'Construction ou démarrage Compose'; }
wait_http http://localhost:8080/actuator/health/liveness
wait_http http://localhost:8082/actuator/health/readiness
http 200 http://localhost:8080/api/movies/whoami; json '.environment == "compose"'
http 201 http://localhost:8082/api/tickets -H 'Content-Type: application/json' -d '{"movieId":1,"seats":2}'; json '.total == 21'
[ "$(docker run --rm --entrypoint id movie-service:1.0.0 -u)" = 10001 ] || fail 'UID de movie différent de 10001'
[ "$(docker run --rm --entrypoint id ticket-service:1.0.0 -u)" = 10001 ] || fail 'UID de ticket différent de 10001'
compose ps
docker image ls movie-service; docker image ls ticket-service
ok 'Images non-root, environnement compose, réservation 21.00'
compose down; COMPOSE_ACTIVE=0

step 'Parties 4 et 5 : Minikube et Ingress'
if ! minikube -p "$PROFILE" status >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --cpus=2 --memory=4096 --keep-context
fi
minikube -p "$PROFILE" image load movie-service:1.0.0 ticket-service:1.0.0
minikube -p "$PROFILE" addons enable ingress
kubectl --context="$PROFILE" -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
mkdir "$CHECK_TMP/k8s"
cp k8s/*.yaml "$CHECK_TMP/k8s/"
# Refaire la partie 4 avec kubernetes, sans modifier le fichier final production.
sed 's/MOVIE_ENVIRONMENT: production/MOVIE_ENVIRONMENT: kubernetes/' k8s/10-config.yaml >"$CHECK_TMP/k8s/10-config.yaml"
kubectl --context="$PROFILE" apply -f "$CHECK_TMP/k8s/" --dry-run=client
RESTORE_CLUSTER=1
kubectl --context="$PROFILE" apply -f "$CHECK_TMP/k8s/"
# Une ConfigMap injectée en env ne change pas les conteneurs déjà en cours.
k rollout restart deploy/movie
ready movie; ready ticket
k get pods,svc,ingress
for service in movie ticket; do
  count=$(k get deploy "$service" -o json | jq '.status.readyReplicas // 0')
  [ "$count" = 2 ] || fail "$service : $count réplica(s) prêt(s), attendu 2"
  addresses=$(k get endpointslices -l "kubernetes.io/service-name=$service" -o json | jq '[.items[].endpoints[] | select(.conditions.ready == true) | .addresses[]] | unique | length')
  [ "$addresses" = 2 ] || fail "$service : $addresses endpoint(s) prêt(s), attendu 2"
done
k exec deploy/ticket -- wget -qO- http://movie:8080/api/movies/whoami >"$CHECK_TMP/body.json"
json '.environment == "kubernetes"'
k exec deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/readiness >"$CHECK_TMP/body.json"
json '.status == "UP" and .components.movie.status == "UP"'
ok 'Deux réplicas et deux endpoints par service, appel DNS interne réussi'
kubectl --context="$PROFILE" -n ingress-nginx port-forward --address=127.0.0.1 svc/ingress-nginx-controller 18080:80 >"$CHECK_TMP/ingress.log" 2>&1 &
FORWARD_PID=$!
sleep 2
kill -0 "$FORWARD_PID" || fail 'Le port local 18080 est occupé ou le port-forward a échoué'
wait_ingress /api/movies; wait_ingress /api/tickets
sleep 5
ingress 200 /api/movies; json 'length == 4'
ingress 201 /api/tickets -H 'Content-Type: application/json' -d '{"movieId":2,"seats":2}'; json '.total == 24'
ingress 201 /api/tickets -H 'Content-Type: application/json' -d '{"movieId":3,"seats":10}'; json '.total == 90'
ingress 404 /actuator/health
: >"$CHECK_TMP/hostnames"
for attempt in $(seq 1 12); do
  ingress 200 /api/movies/whoami
  jq -r .hostname "$CHECK_TMP/body.json" >>"$CHECK_TMP/hostnames"
done
sort -u "$CHECK_TMP/hostnames"
[ "$(sort -u "$CHECK_TMP/hostnames" | wc -l | tr -d ' ')" = 2 ] || fail 'Les appels Ingress n’ont pas atteint les deux Pods movie'
ok 'Ingress : films 200, réservations 24.00 et 90.00, Actuator 404, deux Pods observés'

if [ "$FULL" -eq 1 ]; then
  step 'Partie 6.1 : arrêt de movie'
  k get pods -l app=ticket -o json | jq '[.items[].status.containerStatuses[].restartCount] | add' >"$CHECK_TMP/restarts-before"
  k scale deploy/movie --replicas=0
  sleep 30
  k get pods
  [ "$(k get pods -l app=ticket -o json | jq '[.items[].status.containerStatuses[] | select(.ready)] | length')" = 0 ] || fail 'Ticket est encore prêt après arrêt de movie'
  [ "$(k get endpointslices -l kubernetes.io/service-name=ticket -o json | jq '[.items[].endpoints[] | select(.conditions.ready == true)] | length')" = 0 ] || fail 'Ticket possède encore des endpoints prêts'
  ingress 503 /api/tickets
  k exec deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/liveness >"$CHECK_TMP/body.json"; json '.status == "UP"'
  restarts=$(k get pods -l app=ticket -o json | jq '[.items[].status.containerStatuses[].restartCount] | add')
  [ "$restarts" = "$(cat "$CHECK_TMP/restarts-before")" ] || fail 'Ticket a redémarré pendant la panne'
  ok 'Panne : ticket non prêt, endpoints retirés, HTTP 503, liveness UP, aucun redémarrage'
  k scale deploy/movie --replicas=2
  ready movie; ready ticket; wait_ingress /api/tickets

  step 'Partie 6.2 : trois erreurs successives'
  # Le fichier rendu est corrigé. Recréer les trois erreurs uniquement dans /tmp.
  sed -e 's/imagePullPolicy: IfNotPresent/imagePullPolicy: Always/' -e 's/name: ticket-config$/name: ticket-configmap/' -e 's/port: 8080 }/port: 8081 }/' broken/ticket-debug.yaml >"$CHECK_TMP/ticket-debug.yaml"
  wait_debug() {
    expected=$1
    for attempt in $(seq 1 90); do
      pod=$(k get pods -l app=ticket-debug -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')
      if [ -n "$pod" ]; then
        state=$(k get pod "$pod" -o json)
        case "$expected" in
          image) if printf '%s' "$state" | jq -e 'any(.status.containerStatuses[]?; .state.waiting.reason == "ErrImagePull" or .state.waiting.reason == "ImagePullBackOff")' >/dev/null; then k get pod "$pod"; k describe pod "$pod"; return; fi ;;
          config) if printf '%s' "$state" | jq -e 'any(.status.containerStatuses[]?; .state.waiting.reason == "CreateContainerConfigError")' >/dev/null; then k get pod "$pod"; k describe pod "$pod"; return; fi ;;
          probe) if printf '%s' "$state" | jq -e 'any(.status.containerStatuses[]?; .state.running != null and .ready == false)' >/dev/null; then sleep 10; k get pod "$pod"; k describe pod "$pod"; return; fi ;;
        esac
      fi
      sleep 2
    done
    fail "Erreur de dépannage non observée : $expected"
  }
  if k get deploy ticket-debug >/dev/null 2>&1; then fail 'Un Deployment ticket-debug existe déjà : le supprimer avant ce scénario'; fi
  DEBUG_ACTIVE=1
  k apply -f "$CHECK_TMP/ticket-debug.yaml"; wait_debug image
  sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' "$CHECK_TMP/ticket-debug.yaml" >"$CHECK_TMP/debug-next.yaml"
  mv "$CHECK_TMP/debug-next.yaml" "$CHECK_TMP/ticket-debug.yaml"
  k apply -f "$CHECK_TMP/ticket-debug.yaml"; wait_debug config
  sed 's/name: ticket-configmap/name: ticket-config/' "$CHECK_TMP/ticket-debug.yaml" >"$CHECK_TMP/debug-next.yaml"
  mv "$CHECK_TMP/debug-next.yaml" "$CHECK_TMP/ticket-debug.yaml"
  k apply -f "$CHECK_TMP/ticket-debug.yaml"; wait_debug probe
  k apply -f broken/ticket-debug.yaml
  ready ticket-debug
  k delete -f broken/ticket-debug.yaml; DEBUG_ACTIVE=0
  ok 'Les trois erreurs ont été observées puis corrigées dans l’ordre'

  step 'Partie 6.3 : ConfigMap sans rebuild'
  k apply -f k8s/10-config.yaml
  ingress 200 /api/movies/whoami; json '.environment == "kubernetes"'
  k rollout restart deploy/movie; ready movie
  sleep 10
  ingress 200 /api/movies/whoami; json '.environment == "production"'
  ok 'La nouvelle configuration devient effective après remplacement des Pods'

  step 'Partie 7 : mémoire et remplacement des Pods'
  for attempt in $(seq 1 4); do ingress 201 /api/tickets -H 'Content-Type: application/json' -d '{"movieId":3,"seats":1}'; done
  printf 'Nombres de réservations sur six appels : '
  for attempt in $(seq 1 6); do ingress 200 /api/tickets; jq -r length "$CHECK_TMP/body.json"; done
  k delete pod -l app=ticket
  ready ticket; wait_ingress /api/tickets; sleep 5
  for attempt in $(seq 1 6); do ingress 200 /api/tickets; json 'length == 0'; done
  old_pod=$(k get pod -l app=movie -o jsonpath='{.items[0].metadata.name}')
  k delete pod "$old_pod"
  ready movie
  [ -z "$(k get pod "$old_pod" --ignore-not-found -o name)" ] || fail 'L’ancien Pod existe encore'
  ok 'Réservations perdues après remplacement de ticket ; Pod movie recréé'
fi

step 'Bonus B1 : sécurité'
[ "$(k exec deploy/movie -- id -u)" = 10001 ] || fail 'UID Kubernetes différent de 10001'
if k exec deploy/movie -- touch /test >"$CHECK_TMP/readonly.log" 2>&1; then fail 'La racine du conteneur movie accepte les écritures'; fi
cat "$CHECK_TMP/readonly.log"
grep -q 'Read-only file system' "$CHECK_TMP/readonly.log" || fail 'L’écriture a échoué pour une autre raison que la racine en lecture seule'
k get deploy movie -o json | jq -e '.spec.template.spec.containers[0].securityContext | .runAsNonRoot == true and .runAsUser == 10001 and .allowPrivilegeEscalation == false and .readOnlyRootFilesystem == true and (.capabilities.drop | index("ALL") != null)' >/dev/null || fail 'SecurityContext incomplet'
ok 'UID 10001, racine en lecture seule et securityContext conformes'

if [ "$FULL" -eq 1 ]; then
  step 'Bonus B2 : 300 requêtes pendant un rolling update'
  k get deploy movie -o json | jq -e '.spec.strategy.rollingUpdate | .maxUnavailable == 0 and .maxSurge == 1' >/dev/null || fail 'Stratégie de rolling update incorrecte'
  wait_ingress /api/movies; sleep 10
  k rollout restart deploy/movie
  for attempt in $(seq 1 300); do
    curl --max-time 5 --resolve cinema.local:18080:127.0.0.1 -sS -o /dev/null -w '%{http_code}\n' http://cinema.local:18080/api/movies >>"$CHECK_TMP/rolling-codes" || true
    sleep 0.2
  done
  ready movie
  sort "$CHECK_TMP/rolling-codes" | uniq -c
  [ "$(grep -c '^200$' "$CHECK_TMP/rolling-codes")" = 300 ] || fail 'Au moins une requête a échoué pendant le rolling update'
  ok '300 réponses HTTP 200 sur 300 pendant le rolling update'
fi

step 'Rétablissement de la configuration finale'
kubectl --context="$PROFILE" apply -f k8s/
k rollout restart deploy/movie
ready movie
RESTORE_CLUSTER=0
k exec deploy/movie -- wget -qO- http://localhost:8080/api/movies/whoami >"$CHECK_TMP/body.json"
final_environment=$(k get configmap movie-config -o jsonpath='{.data.MOVIE_ENVIRONMENT}')
json ".environment == \"$final_environment\""
ok "Configuration finale rétablie : $final_environment"

step 'Résultat'
printf '%s vérifications réussies.\n' "$PASS"
printf 'Cluster conservé : minikube -p %s status\n' "$PROFILE"
printf 'Pour le consulter : kubectl --context=%s -n cinema-exam get pods,svc,ingress\n' "$PROFILE"
printf 'Les JAR locaux, Compose et le port-forward temporaires seront arrêtés.\n'
