# Examen CinéK8s — Mathieu ROBERT

## Partie 1

Q1.1

MovieClient utilise la propriété movie.url. On peut la remplacer avec la variable d’environnement MOVIE_URL, que Spring Boot associe à cette propriété.

Q1.2

Si le film n’existe pas, ticket renvoie 422. Si le nombre de places est insuffisant, il renvoie 409. Si movie ne répond pas, il renvoie 503. Le 404 de movie est donc transformé en 422 par ticket.

Q1.3

La ligne à compléter est : include: readinessState,movie.
La dépendance à movie doit être dans la readiness pour arrêter d’envoyer des requêtes à ticket quand movie est indisponible. La mettre dans la liveness ferait redémarrer ticket alors que le problème vient de movie.

Q1.4

| Endpoint | Probe | Conséquence après le seuil d’échecs |
|---|---|---|
| /actuator/health/liveness | startupProbe et livenessProbe | Redémarrage du conteneur ; la startupProbe suspend les autres probes jusqu’à son premier succès. |
| /actuator/health/readiness | readinessProbe | Pod non prêt, retiré des destinations prêtes du Service, sans redémarrage. |

server.shutdown: graceful permet aux requêtes en cours de finir pendant l’arrêt de l’ancienne instance lors d’un rolling update.

## Partie 2

```text
$ POST ticket {movieId:2,seats:3}
HTTP 201
{"id":1,"movieId":2,"movieTitle":"Le Seigneur des Pods","seats":3,"total":36.00,"createdAt":"2026-10-08T08:59:10.222957Z"}

$ GET ticket readiness
HTTP 200
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}

$ GET ticket readiness après arrêt movie
HTTP 503
{"status":"DOWN","components":{"movie":{"status":"DOWN","details":{"error":"I/O error on GET request for \"http://localhost:8080/actuator/health/liveness\": null"}},"readinessState":{"status":"UP"}}}

$ GET ticket liveness après arrêt movie
HTTP 200
{"status":"UP"}

$ POST ticket après arrêt movie
HTTP 503
{"timestamp":"2026-10-08T08:59:10.322+00:00","status":503,"error":"Service Unavailable","path":"/api/tickets"}
```

Q2.1

SERVER_PORT=8082 évite que les deux services utilisent le même port sur la machine. Spring Boot permet de remplacer server.port par une variable d’environnement grâce au relaxed binding, sans modifier application.yaml.

Q2.2

Ticket fonctionne encore, mais il ne peut plus vérifier les films pour une réservation. Sa readiness passe donc à DOWN, tandis que sa liveness reste UP. Redémarrer ticket ne réglerait pas la panne de movie.

## Partie 3

```text
$ docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' movie-service
movie-service:1.0.0 232MB
$ docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' ticket-service
ticket-service:1.0.0 232MB
$ docker run --rm --entrypoint id movie-service:1.0.0
uid=10001(spring) gid=101(spring) groups=101(spring)
$ curl -fsS http://localhost:8080/api/movies/whoami
{"environment":"compose","hostname":"e82570d67ed2"}
$ curl --retry 30 --retry-delay 1 --retry-connrefused --retry-all-errors -fsS http://localhost:8082/api/tickets -H 'Content-Type: application/json' -d '{"movieId":1,"seats":2}'
{"id":1,"movieId":1,"movieTitle":"Pod Fiction","seats":2,"total":21.00,"createdAt":"2026-10-08T09:03:16.097526376Z"}
```

Q3.1

Les dépendances sont téléchargées dans une couche Docker avant la copie des sources. Si seule une ligne de Java change, Docker garde cette couche en cache et relance la compilation. Les dépendances ne sont téléchargées à nouveau que si le pom.xml change ou si le cache manque.

Q3.2

MaxRAMPercentage=75 adapte la taille maximale du heap à la mémoire du conteneur. Avec -Xmx512m, cette taille reste fixée à 512 Mo, même si la limite du conteneur change. Il faut aussi garder de la mémoire pour le reste de la JVM, pas seulement pour le heap.

Q3.3

Les Pods ticket peuvent démarrer avant movie. Leur readiness échoue tant que movie ne répond pas, donc ils ne reçoivent pas de trafic du Service. Ils deviennent prêts quand movie est disponible, sans avoir besoin de redémarrer.

## Partie 4

```text
$ kubectl -n cinema-exam get pods
NAME                      READY   STATUS    RESTARTS   AGE
movie-59684459f4-hhmlq    1/1     Running   0          21s
movie-59684459f4-nd2rn    1/1     Running   0          21s
ticket-66d95c98b6-9m6pq   1/1     Running   0          21s
ticket-66d95c98b6-9p899   1/1     Running   0          21s
$ kubectl -n cinema-exam get endpoints movie ticket
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME     ENDPOINTS                           AGE
movie    10.244.0.11:8080,10.244.0.12:8080   21s
ticket   10.244.0.13:8080,10.244.0.14:8080   21s
$ kubectl -n cinema-exam get endpointslices -l kubernetes.io/service-name
NAME           ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
movie-tdwdb    IPv4          8080    10.244.0.12,10.244.0.11   21s
ticket-8zzbt   IPv4          8080    10.244.0.14,10.244.0.13   21s
$ kubectl -n cinema-exam exec deploy/ticket -- wget -qO- http://movie:8080/api/movies/whoami
{"environment":"kubernetes","hostname":"movie-59684459f4-hhmlq"}
$ kubectl -n cinema-exam exec deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/readiness
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}
$ curl --retry 30 --retry-delay 1 --retry-connrefused --retry-all-errors -fsS http://localhost:8082/api/tickets -H 'Content-Type: application/json' -d '{"movieId":2,"seats":2}'
{"id":1,"movieId":2,"movieTitle":"Le Seigneur des Pods","seats":2,"total":24.00,"createdAt":"2026-10-08T09:03:56.002526631Z"}
```

Q4.1

Les fichiers de ce dossier sont lus dans l’ordre de leur nom : 00, 10, 20, 30 puis 40. Les préfixes placent le namespace et les ConfigMaps avant les Deployments. Cela ne veut pas dire que kubectl attend la fin du démarrage des Pods avant de passer au fichier suivant.

Q4.2

La startupProbe attend le démarrage de Spring Boot. Pendant ce temps, les autres probes sont suspendues et le Pod reste à 0/1. Ensuite, la readiness vérifie qu’il peut recevoir du trafic. Pour ticket, movie doit aussi être disponible. Ce délai au démarrage est normal.

Q4.3

Avec Always, Kubernetes contacte le registre pour résoudre l’image. Les images du TP ont été chargées dans Minikube et ne sont pas publiées sur Docker Hub. Le téléchargement échoue donc avec ErrImagePull, puis ImagePullBackOff.

## Partie 5

```text
$ curl --max-time 15 -sS -w '\nHTTP %{http_code}\n' http://cinema.local/api/movies
[{"id":1,"title":"Pod Fiction","genre":"Thriller","price":10.50,"seats":80},{"id":2,"title":"Le Seigneur des Pods","genre":"Fantasy","price":12.00,"seats":3},{"id":3,"title":"Docker Wars","genre":"Science-fiction","price":9.00,"seats":150},{"id":4,"title":"Rollback to the Future","genre":"Comédie","price":8.50,"seats":0}]
HTTP 200

$ curl --max-time 15 -sS -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' -d '{"movieId":3,"seats":10}' http://cinema.local/api/tickets
{"id":2,"movieId":3,"movieTitle":"Docker Wars","seats":10,"total":90.00,"createdAt":"2026-10-08T09:21:00.207112757Z"}
HTTP 201

Six appels à http://cinema.local/api/movies/whoami :
movie-7bd695464f-9pr78
movie-7bd695464f-9pr78
movie-7bd695464f-9pr78
movie-7bd695464f-4l9c4
movie-7bd695464f-9pr78
movie-7bd695464f-4l9c4
Nombre de Pods distincts : 2

$ curl --max-time 15 -sS -o /dev/null -w 'HTTP %{http_code}\n' http://cinema.local/actuator/health
HTTP 404

$ kubectl -n cinema-exam get pods,ingress
NAME                          READY   STATUS    RESTARTS   AGE
pod/movie-7bd695464f-4l9c4    1/1     Running   0          11m
pod/movie-7bd695464f-9pr78    1/1     Running   0          11m
pod/ticket-66d95c98b6-thxdg   1/1     Running   0          15m
pod/ticket-66d95c98b6-zfnjn   1/1     Running   0          15m

NAME                               CLASS   HOSTS          ADDRESS        PORTS   AGE
ingress.networking.k8s.io/cinema   nginx   cinema.local   192.168.49.2   80      18m
```

Q5.1

Deux Pods movie différents ont répondu aux six appels. Le Service donne les destinations prêtes et le contrôleur Ingress NGINX répartit les requêtes entre elles. Les noms ne sont pas obligés d’alterner à chaque appel.

Q5.2

Avec Exact, la règle /api/movies ne correspondrait pas à /api/movies/1. Sans autre règle pour ce chemin, la réponse serait 404.

Q5.3

La réponse est 404, car aucune règle de l’Ingress ne correspond à /actuator/health. Cela évite d’exposer les informations de santé de l’application par cet accès. Les probes peuvent toujours joindre Actuator dans le cluster.

## Partie 6

6.1

Prédictions avant l’arrêt de movie :

a) Ticket reste Running, passe à 0/1 et garde RESTARTS à 0.
b) Le Service ticket n’a plus d’endpoints prêts.
c) GET /api/tickets via l’Ingress renvoie 503.
d) La liveness de ticket reste UP.

```text
$ kubectl -n cinema-exam scale deploy/movie --replicas=0
deployment.apps/movie scaled
$ kubectl -n cinema-exam get pods
NAME                      READY   STATUS    RESTARTS   AGE
ticket-66d95c98b6-9m6pq   0/1     Running   0          54s
ticket-66d95c98b6-9p899   0/1     Running   0          54s
$ kubectl -n cinema-exam get endpoints movie ticket
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME     ENDPOINTS   AGE
movie    <none>      54s
ticket               54s
$ kubectl -n cinema-exam get endpointslices -l kubernetes.io/service-name
NAME           ADDRESSTYPE   PORTS     ENDPOINTS                 AGE
movie-tdwdb    IPv4          <unset>   <unset>                   54s
ticket-8zzbt   IPv4          8080      10.244.0.14,10.244.0.13   54s
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/tickets
<html>
<head><title>503 Service Temporarily Unavailable</title></head>
<body>
<center><h1>503 Service Temporarily Unavailable</h1></center>
<hr><center>nginx</center>
</body>
</html>

HTTP 503
$ kubectl -n cinema-exam exec deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/liveness
{"status":"UP"}
```

Q6.1

1. Movie est réduit à zéro réplica et n’a plus de backend disponible.
2. MovieHealthIndicator ne peut plus joindre movie ; la readiness ticket échoue.
3. Après le seuil d’échecs, les Pods ticket sont retirés des destinations prêtes du Service.
4. NGINX ne dispose plus de backend prêt pour ticket et renvoie 503.

La liveness reste UP : les conteneurs ne sont pas redémarrés, et RESTARTS reste à 0. Après restauration de movie à deux réplicas, ticket retrouve automatiquement sa readiness, sans intervention sur son Deployment.

6.2

| # | Statut observé | Commande de diagnostic | Cause exacte | Correction apportée |
|---|---|---|---|---|
| 1 | ErrImagePull, puis événement ImagePullBackOff | kubectl -n cinema-exam describe pod ticket-debug-6bc9655bd5-m7bcb | Always tente Docker Hub : pull access denied pour l’image uniquement locale. | imagePullPolicy: IfNotPresent |
| 2 | CreateContainerConfigError | kubectl -n cinema-exam describe pod ticket-debug-748f79d8cf-t4hc7 | configmap "ticket-configmap" not found | Référence ticket-config |
| 3 | Running, READY 0/1 | kubectl -n cinema-exam describe pod ticket-debug-c9999c4dc-hsfcp | Readiness sur 8081 : connection refused, application sur 8080. | Port de probe 8080 |

```text
$ kubectl apply -f broken/ticket-debug.yaml
deployment.apps/ticket-debug configured
$ kubectl -n cinema-exam get pods -l app=ticket-debug
NAME                           READY   STATUS        RESTARTS   AGE
ticket-debug-56f4f5848-mf262   1/1     Running       0          7s
ticket-debug-c9999c4dc-hsfcp   0/1     Terminating   0          21s
$ kubectl delete -f broken/ticket-debug.yaml
deployment.apps "ticket-debug" deleted from cinema-exam namespace
```

6.3

```text
$ kubectl apply -f k8s/10-config.yaml
configmap/movie-config configured
configmap/ticket-config unchanged
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/movies/whoami
{"hostname":"movie-59684459f4-57x9s","environment":"kubernetes"}
HTTP 200
$ kubectl -n cinema-exam rollout restart deploy/movie
deployment.apps/movie restarted
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/movies/whoami
{"environment":"production","hostname":"movie-8678449bcc-pgwgk"}
HTTP 200
```

Q6.3

Les variables d’environnement d’un conteneur ne changent pas quand la ConfigMap est modifiée. Le rollout restart remplace les Pods, qui récupèrent alors la nouvelle valeur au démarrage. Il n’y a pas besoin de reconstruire l’image.

## Partie 7

Q7.1

CoreDNS résout movie dans le namespace cinema-exam et renvoie la ClusterIP du Service movie. Ticket envoie sa requête à cette adresse sur le port 8080. Le réseau du Service la dirige vers un Pod movie prêt, sélectionné avec le label app: movie, sur son port http.

Q7.2

Chaque Pod ticket a sa propre liste de réservations en mémoire. Selon le Pod qui répond, le nombre peut donc changer. Quand les Pods sont supprimés, leurs réservations sont perdues. Pour les conserver et les partager, il faudrait une base de données persistante commune aux deux instances.

```text
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/tickets -H 'Content-Type: application/json' -d '{"movieId": 3, "seats": 1}'
{"id":2,"movieId":3,"movieTitle":"Docker Wars","seats":1,"total":9.00,"createdAt":"2026-10-08T09:06:01.226200883Z"}
HTTP 201
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/tickets -H 'Content-Type: application/json' -d '{"movieId": 3, "seats": 1}'
{"id":2,"movieId":3,"movieTitle":"Docker Wars","seats":1,"total":9.00,"createdAt":"2026-10-08T09:06:01.248490716Z"}
HTTP 201
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/tickets -H 'Content-Type: application/json' -d '{"movieId": 3, "seats": 1}'
{"id":3,"movieId":3,"movieTitle":"Docker Wars","seats":1,"total":9.00,"createdAt":"2026-10-08T09:06:01.272687133Z"}
HTTP 201
$ curl --max-time 10 -sS --resolve cinema.local:18080:127.0.0.1 -w '\nHTTP %{http_code}\n' http://cinema.local:18080/api/tickets -H 'Content-Type: application/json' -d '{"movieId": 3, "seats": 1}'
{"id":3,"movieId":3,"movieTitle":"Docker Wars","seats":1,"total":9.00,"createdAt":"2026-10-08T09:06:01.298083133Z"}
HTTP 201

Nombre de réservations (10 appels) : [3, 3, 3, 3, 3, 3, 3, 3, 3, 3]
$ kubectl -n cinema-exam delete pods -l app=ticket
pod "ticket-66d95c98b6-9m6pq" deleted from cinema-exam namespace
pod "ticket-66d95c98b6-9p899" deleted from cinema-exam namespace

Après remplacement des Pods : [0, 0, 0, 0, 0, 0]
```

Pendant ce test, les quatre nouvelles réservations se sont réparties également. Avec les réservations précédentes, chaque Pod en avait trois, donc le nombre affiché ne variait pas. Les identifiants identiques dans les réponses viennent des compteurs séparés des deux Pods. Après leur suppression, toutes les listes sont vides.

Q7.3

Un nouveau Pod movie remplace celui qui a été supprimé. Le ReplicaSet maintient les deux réplicas demandés par le Deployment. Un Pod seul ne serait pas recréé après sa suppression et ne bénéficierait pas de la gestion des réplicas et des mises à jour du Deployment.

```text
$ kubectl -n cinema-exam get pods -l app=movie
NAME                     READY   STATUS    RESTARTS   AGE
movie-8678449bcc-pgwgk   1/1     Running   0          91s
movie-8678449bcc-wltcl   1/1     Running   0          87s
$ kubectl -n cinema-exam delete pod movie-8678449bcc-pgwgk
pod "movie-8678449bcc-pgwgk" deleted from cinema-exam namespace
$ kubectl -n cinema-exam get pods -l app=movie
NAME                     READY   STATUS    RESTARTS   AGE
movie-8678449bcc-wlqxz   0/1     Running   0          1s
movie-8678449bcc-wltcl   1/1     Running   0          88s
$ kubectl -n cinema-exam get pods -l app=movie
NAME                     READY   STATUS    RESTARTS   AGE
movie-8678449bcc-wlqxz   1/1     Running   0          5s
movie-8678449bcc-wltcl   1/1     Running   0          92s
```
