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
