# Weather Images — Azure Container Apps

An HTTP API that generates a fresh set of images, one per Dutch weather station,
with the current weather written onto each image. The work runs in the background
through Azure Storage Queues so the initial call returns immediately.

Student: Robben Lê (707875) · Inholland — Cloud Computing minor

## What it does

```
 Client            API                start-job        Job 1             process-image     Job 2            Blob Storage
 (.http file)      (Container App)    (queue)          (FetchWeather)    (queue)           (ProcessImage)   (container "images")
 ──────────        ───────────────    ─────────        ──────────────    ─────────────     ──────────────   ────────────────────
     │                   │                │                  │                 │                 │                   │
     │─(1) POST /api/images─▶            │                  │                 │                 │                   │
     │                   │─(2) send jobId─▶                 │                 │                 │                   │
     │◀─(3) 202 + jobId──│                │                  │                 │                 │                   │
     │                   │                │                  │                 │                 │                   │
     │                   │                │──(4) KEDA starts─▶                 │                 │                   │
     │                   │                │◀─(5) delete msg──│                 │                 │                   │
     │                   │                │                  │─(6) 40 msgs────▶│                 │                   │
     │                   │                │                  │                 │──(7) KEDA──────▶│  up to 10 parallel
     │                   │                │                  │                 │                 │─(8) fetch image──▶ picsum.photos
     │                   │                │                  │                 │                 │─(9) draw text
     │                   │                │                  │                 │                 │─(10) upload ──────▶
     │                   │                │                  │                 │◀(11) delete msg─│                   │
     │                   │                │                  │                 │                 │                   │
     │─(12) GET /api/images/{jobId}─▶     │                  │                 │                 │                   │
     │◀─ list of image URLs ──────────────────────────────────────────────────────────────────────────────────────────│
```

## Requirement → where it lives

| Must | File |
|---|---|
| Public API for requesting fresh images | `src/WeatherImages.Api/Program.cs` → `MapPost("/api/images")` |
| Queues so the initial call stays fast | same — sends a message and returns `202 Accepted` immediately |
| Blob Storage stores and exposes the images | `src/WeatherImages.Jobs.ProcessImage/Program.cs` → `UploadAsync`; `infra/main.bicep` → `publicAccess: 'Blob'` |
| Queue Storage: create, read **and delete** | `FetchWeather` (send + delete), `ProcessImage` (receive + delete) |
| Buienradar API | `src/WeatherImages.Jobs.FetchWeather/Program.cs` |
| Public image API | `src/WeatherImages.Jobs.ProcessImage/Program.cs` → `picsum.photos` |
| Public API for fetching generated images | `src/WeatherImages.Api/Program.cs` → `MapGet("/api/images/{jobId}")` |
| HTTP files as API documentation | `src/WeatherImages.Api/WeatherImages.Api.http` |
| Bicep template (including the queues) | `infra/main.bicep` |
| GitHub repo + Hijdra added | repository collaborators |
| `deploy.ps1` | `deploy.ps1` |
| **Multiple** queues | `src/WeatherImages.Shared/StorageNames.cs` → `start-job`, `process-image` |
| Deployed to Azure with a working endpoint | see `WeatherImages.Api.http` |

## Projects

| Project | Runs as | Purpose |
|---|---|---|
| `WeatherImages.Shared` | class library | `ProcessImageMessage` (the contract between the jobs), queue/container names, configuration |
| `WeatherImages.Api` | Container App | HTTP endpoints |
| `WeatherImages.Jobs.FetchWeather` | Container Apps Job | reads `start-job`, fetches Buienradar, fans out one message per station |
| `WeatherImages.Jobs.ProcessImage` | Container Apps Job | reads `process-image`, draws the weather onto an image, uploads it |

`ProcessImageMessage` lives in `Shared` on purpose: it is the contract between the
two jobs, so a change on one side breaks the build on the other instead of
failing silently at runtime.

## Running locally

```powershell
.\setenv.ps1                                            # sets STORAGE_CONNECTION and APP
dotnet build
Invoke-RestMethod -Method Post -Uri "$env:APP/api/images"
dotnet run --project src/WeatherImages.Jobs.FetchWeather
dotnet run --project src/WeatherImages.Jobs.ProcessImage
```

`setenv.ps1` reads the connection string from Azure at run time. No secret is
stored in the repository.

## Deploying

```powershell
.\deploy.ps1
```

The script publishes all three projects with the dotnet CLI, builds and pushes
three container images tagged with a timestamp, and deploys every resource from
`infra/main.bicep`. Re-running it is safe: Bicep is idempotent, and the CLI steps
check before creating.

## Design decisions

**Blob naming — `{jobId}/{stationId}.png`.** Blob Storage has no real folders, but
listing by prefix is fast. `GET /api/images/{jobId}` lists everything with the
prefix `{jobId}/`, which is how the results endpoint works without a database.
Using `stationId` rather than the station name keeps the URL free of spaces.

**Upload before delete.** The queue message is deleted only after the image has
been uploaded. If the job crashes in between, the message reappears after the
visibility timeout and another replica redoes the work. The worst case is an
image written twice; the alternative would lose a station permanently.

**Secrets.** Connection strings are built inside the Bicep template with
`listKeys()` at deployment time and stored as Container App secrets. The
repository contains the expression, never the key.

## Known limitations

**Buienradar returns 40–43 stations, not 50.** The assignment says 50; the live
feed returns fewer and the number varies. The code uses `stations.Count` rather
than a hard-coded 50.

**Status is approximate.** `GET /api/images/{jobId}` reports `Pending` when no
blobs exist yet and `Ready` otherwise. It cannot distinguish "still running" from
"finished", because nothing records how many images a job should produce. Table
Storage (a Could requirement) is the proper fix.

**The blob container is public.** Anyone with a URL can read an image, although
the container cannot be listed. Replacing this with SAS tokens is a Could
requirement and is marked with `TODO` in `infra/main.bicep`.

**Text contrast.** The base image comes from a random-image API, so white text is
hard to read on light photographs.

**Region split.** Storage, container registry, managed identity and Log Analytics
run in **Sweden Central**; the Container Apps environment and its three workloads
run in **Norway East**.

Azure Container Apps recently introduced *express* environments, which provision
quickly but do not support Container Apps Jobs. For this subscription, Sweden
Central produced an express environment however the environment was created —
from Bicep, from the CLI with `--enable-workload-profiles true`, and with an
explicit `infrastructureResourceGroup`. Norway East does not, so the environment
was created there. Cross-region calls add a few tens of milliseconds, which is
acceptable for a batch image pipeline.

Because ARM and Bicep have no flag for this, the environment is created by
`deploy.ps1` with the Azure CLI and referenced in `main.bicep` with `existing` —
the same pattern used in the course sample `container-app-image.bicep`.

**One environment per subscription.** Azure for Students allows a single Container
Apps environment, so the API and both jobs share one environment.

## Could requirements — not implemented

- SAS tokens instead of a public blob container
- GitHub Actions build and deploy
- Authentication on the request API
- Table Storage for real job status


###### Trying the API

The requests are documented in `src/WeatherImages.Api/WeatherImages.Api.http`.
That format is supported natively by Visual Studio 2022 and JetBrains Rider, and
by the REST Client extension in VS Code.

If you would rather not use an editor, everything can be tested from a terminal
or a browser.

**Base URL**

```
https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io
```

**1. Start a job** (returns a job id)

```bash
curl -X POST https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io/api/images
```

The work runs in the background through two queue-triggered Container Apps Jobs.
KEDA polls every 30 seconds, so allow about 2-3 minutes before all images exist.

**2. Fetch the status and the image links**

```bash
curl https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io/api/images/<jobId>
```

`"status": "Pending"` with `"imageCount": 0` means the jobs have not finished yet.

**3. A completed job, ready to inspect immediately** — open in a browser:

<https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io/api/images/ac626648-67b0-4c40-a68b-8991de53e889>

**4. One generated image, served from Blob Storage** — open in a browser:

<https://stweatherimg707875.blob.core.windows.net/images/ac626648-67b0-4c40-a68b-8991de53e889/6215.png>

> `POST /api/images` cannot be opened in a browser: browsers send `GET`, and the
> endpoint answers `405 Method Not Allowed`. Use curl, or the `.http` file.