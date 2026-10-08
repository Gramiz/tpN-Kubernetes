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
