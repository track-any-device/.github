# Track Any Device

[![Status](https://img.shields.io/badge/status-in%20development-orange?style=flat-square)](https://track-any-device.com)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![PHP](https://img.shields.io/badge/PHP-8.3-777BB4?style=flat-square&logo=php&logoColor=white)](https://php.net)
[![Laravel](https://img.shields.io/badge/Laravel-13-FF2D20?style=flat-square&logo=laravel&logoColor=white)](https://laravel.com)
[![Next.js](https://img.shields.io/badge/Next.js-15-000000?style=flat-square&logo=next.js&logoColor=white)](https://nextjs.org)
[![Go](https://img.shields.io/badge/Go-1.23-00ADD8?style=flat-square&logo=go&logoColor=white)](https://go.dev)
[![React Native](https://img.shields.io/badge/React%20Native-Expo-0088CC?style=flat-square&logo=expo&logoColor=white)](https://expo.dev)

**Multi-tenant fleet tracking platform** — real-time GPS, multi-protocol device support, workflow automation, and a full tenant operational portal.

> **We are actively building.** The platform is in development — features are shipping continuously.
> Visit [track-any-device.com](https://track-any-device.com) to follow progress.

---

## What We're Building

Track Any Device is a SaaS fleet tracking platform for organisations that need to monitor vehicles, assets, and field personnel across complex operational environments.

**Core capabilities:**

- **Multi-protocol device support** — JT/T 808-2019 TCP, GT06/Concox binary TCP, H02/Sinotrack ASCII TCP+UDP, TAD-101 WebSocket, SMS fallback. One platform, any GPS hardware.
- **Multi-tenant architecture** — each organisation gets an isolated subdomain portal (`{slug}.track-any-device.com`) with full data separation at the query layer.
- **Real-time tracking** — live map, device location streams, SOS alerts, geofence violations — all pushed via WebSocket.
- **Beat geo-fencing** — define patrol zones (polygons or circles), assign devices, and detect violations automatically.
- **Workflow automation** — JSON-driven automation graphs triggered by incidents or time schedules. Actions include notifications, device commands, escalation, and webhooks.
- **AI-ready** — built-in MCP server exposes fleet data to AI assistants with tenant-scoped access control.
- **Mobile** — iOS and Android apps (TAD-101 protocol) for personnel tracking.

---

## Architecture

```
                        ┌─────────────────────────────────────────────────┐
                        │               track-any-device.com               │
                        │  Next.js 15 — marketing site + "my" user portal  │
                        └──────────────┬──────────────────────┬────────────┘
                                       │ REST API              │ GraphQL
                        ┌──────────────▼──────────┐  ┌────────▼────────────┐
                        │  app  (API brain)        │  │  server-graphql      │
                        │  Laravel 13              │  │  Lighthouse          │
                        │  queue · cron · cli      │  │  public content +    │
                        │  REST: mobile, my, tenant│  │  central staff       │
                        └──────────────────────────┘  └─────────────────────┘
                                       │ packages
         ┌─────────────────────────────┼────────────────────────────────────┐
         │                             │                                     │
┌────────▼──────────┐      ┌───────────▼────────────┐         ┌─────────────▼──────┐
│  server-tenant    │      │  server-login           │         │  server-admin       │
│  Laravel 13       │      │  SSO identity provider  │         │  Filament v4        │
│  Inertia + React  │      │  Laravel Passport        │         │  central staff      │
│  {slug}.tad.com   │      │  login.tad.com           │         │  admin.tad.com      │
└───────────────────┘      └─────────────────────────┘         └────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │  Protocol Gateway — Go 1.23 TCP/UDP servers → Redis Streams → Laravel consumers  │
  │                                                                                  │
  │  server-jt808   :7018  JT/T 808-2019 binary TCP → jt808:telemetry (Redis DB 0)  │
  │  server-gt06    :7019  GT06/Concox binary TCP   → gt06:telemetry  (Redis DB 1)  │
  │  server-h02-tcp :7020  H02/Sinotrack ASCII TCP  → h02:telemetry   (Redis DB 2)  │
  │  server-h02-udp :7021  H02/Sinotrack ASCII UDP  → h02:telemetry   (Redis DB 2)  │
  └──────────────────────────────────────────────────────────────────────────────────┘

         ┌─────────────────────────────────────────────────────────────────┐
         │  mobile-app  (React Native / Expo)                              │
         │  iOS + Android → app/ REST API                                  │
         └─────────────────────────────────────────────────────────────────┘
```

---

## Repositories

### PHP Packages — published to [Packagist](https://packagist.org/packages/track-any-device/) as `track-any-device/*`

| Repository | Package | Purpose |
|---|---|---|
| [package-core](https://github.com/track-any-device/package-core) | `track-any-device/core` | Domain models, migrations, seeders, shared services, events, jobs |
| [package-drivers](https://github.com/track-any-device/package-drivers) | `track-any-device/drivers` | GPS device protocol adapters (GF07, AOT120, P901) |
| [package-jt808](https://github.com/track-any-device/package-jt808) | `track-any-device/jt808` | JT/T 808-2019 stream consumer and command dispatcher |
| [package-gt06](https://github.com/track-any-device/package-gt06) | `track-any-device/gt06` | GT06/Concox stream consumer and command dispatcher |
| [package-h02](https://github.com/track-any-device/package-h02) | `track-any-device/h02` | H02/Sinotrack stream consumer (TCP + UDP) |
| [package-tad101](https://github.com/track-any-device/package-tad101) | `track-any-device/tad101` | TAD-101 WebSocket device protocol |
| [package-sms-gateway](https://github.com/track-any-device/package-sms-gateway) | `track-any-device/sms-gateway` | SMS HTTP gateway client |
| [package-sso-server](https://github.com/track-any-device/package-sso-server) | `track-any-device/sso-server` | OAuth2 identity provider (Laravel Passport) |
| [package-sso-client](https://github.com/track-any-device/package-sso-client) | `track-any-device/sso-client` | OAuth2 consumer — SSO callback and session bridge (Socialite) |
| [package-mcp](https://github.com/track-any-device/package-mcp) | `track-any-device/mcp` | MCP server — exposes fleet data to AI assistants |
| [package-admin](https://github.com/track-any-device/package-admin) | `track-any-device/admin` | Filament v4 admin resources, pages, and widgets |

### Frontend Package — published to [npm](https://www.npmjs.com/package/@trackany-device/components)

| Repository | Package | Purpose |
|---|---|---|
| [ui-kit](https://github.com/track-any-device/ui-kit) | `@trackany-device/components` | Shared React 19 component library — works in Inertia, Next.js, and Storybook via Platform Adapter |

### Server Applications — published as Docker images to [Docker Hub](https://hub.docker.com/u/trackanydevice)

| Repository | Image | Purpose |
|---|---|---|
| [app](https://github.com/track-any-device/app) | `server-api` · `server-queue` · `server-cron` · `server-cli` | Pure API server — REST (mobile, my portal, tenant portal), queue, scheduler, CLI. No Inertia pages. |
| [server-tenant](https://github.com/track-any-device/server-tenant) | `server-tenant` | Tenant operational portal — live map, incidents, beats, workflows |
| [server-login](https://github.com/track-any-device/server-login) | `server-login` | SSO identity provider — Fortify auth + OAuth2 authorization server |
| [server-admin](https://github.com/track-any-device/server-admin) | `server-admin` | Central admin panel (Filament v4) |
| [server-graphql](https://github.com/track-any-device/server-graphql) | `server-graphql` | GraphQL API — public content and central staff queries |
| [server-jt808](https://github.com/track-any-device/server-jt808) | `server-jt808` | Go TCP server for JT/T 808-2019 GPS devices |
| [server-gt06](https://github.com/track-any-device/server-gt06) | `server-gt06` | Go TCP server for GT06/Concox binary GPS devices |
| [server-h02](https://github.com/track-any-device/server-h02) | `server-h02-tcp` · `server-h02-udp` | Go TCP+UDP server for H02/Sinotrack ASCII GPS devices |
| [web](https://github.com/track-any-device/web) | `server-web` | Next.js 15 — marketing site and authenticated "my" user portal |
| [mobile-app](https://github.com/track-any-device/mobile-app) | — | React Native / Expo — iOS and Android apps |

---

## For Developers

### Three rules that apply in every repository

**1. Cross-repo changes require a GitHub issue first.**

If work in this repository requires a change in another package or server app — stop. Open a GitHub issue in the target repository describing exactly what is needed and why. Reference that issue number in your commit message and PR. Do not reach into another repository's code directly. When an agent picks up a cross-repo issue, it works only within that repository's scope.

**2. Release order: packages before server apps.**

A server app must never be updated to require a package version before that package is tagged and published. The strict dependency order is:

```
package-sms-gateway
  └─ package-core
       ├─ package-drivers
       ├─ package-jt808
       ├─ package-gt06
       ├─ package-h02
       ├─ package-tad101
       ├─ package-sso-server
       ├─ package-sso-client
       ├─ package-mcp
       └─ package-admin
ui-kit                          (parallel with packages — independent)
  └─ server-login
  └─ server-graphql
  └─ server-admin
  └─ server-jt808
  └─ server-gt06
  └─ server-h02
  └─ server-tenant
  └─ app
       └─ web
       └─ mobile-app
```

**3. All database changes belong in `package-core`.**

Models, migrations, and seeders live exclusively in `track-any-device/core`. No migration files in server app repositories. No new Eloquent models in server apps — add to `package-core` first, cut a release, then update the server app's composer dependency. This keeps the database layer consistent across every surface.

---

### Package dependency graph

```
sms-gateway ──────────────────────────────────────► core
                                                      │
          ┌──────────────┬──────────┬────────────────┬┴──────────────┬──────────────┐
          │              │          │                │               │              │
       drivers         jt808      gt06             h02           tad101     sso-server/sso-client
                                                                                   │
                                                                               server-login
                                                                               server-tenant
                                                                               server-graphql
                                                                                   app
```

---

### How releases work

| Repo type | Versioning | Trigger |
|---|---|---|
| PHP packages | Semantic (auto-tag on merge to `main`) | `mathieudutour/github-tag-action` — patch bump by default; use conventional commits for minor/major |
| `ui-kit` | Semantic (semantic-release, conventional commits) | `fix:` → patch · `feat:` → minor · `BREAKING CHANGE` → major |
| Server apps | `v0.1.{commit-count}-{short-sha}` | Build on merge to `main`, Docker image pushed to Docker Hub |

### Branching

```
main                         ← protected, no direct push
feature/issue-{n}-{slug}     ← feature work
hotfix/issue-{n}-{slug}      ← production fixes
```

---

*Track Any Device is built and maintained by the [track-any-device](https://github.com/track-any-device) team.*
