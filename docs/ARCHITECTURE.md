# Architecture — IT-Stack POSTGRESQL

## Overview

PostgreSQL hosts all service databases: Keycloak, Nextcloud, Mattermost, Zammad, SuiteCRM, Odoo, OpenKM, Taiga, Snipe-IT, and GLPI.

## Role in IT-Stack

- **Category:** database
- **Phase:** 1
- **Server:** lab-db1 (10.0.50.12)
- **Ports:** 5432 (PostgreSQL)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → postgresql → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
