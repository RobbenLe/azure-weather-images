# Weather Images on Azure

An HTTP API that starts a background image-creation process and returns a unique job id. That id is then used to fetch the status of the job and, once it is finished, the links to the generated images.

Each image is a random public photo with live Dutch weather data drawn on top of it — one image per weather station in the Buienradar feed. The images are stored in and served from Azure Blob Storage.

Built for the Azure + GitHub assignment of the Cloud Computing minor at Inholland, by **Robben Lê** (student number **707875**).

**Live endpoint:** `https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io`

---

## How it works

The initial HTTP call stays fast because it does no work itself. It only drops a message on a queue and returns immediately. Everything after that runs in the background, driven by two Container Apps Jobs that Azure starts automatically when their queue is not empty.

```
 Client            API                start-job        FetchWeather       process-image      ProcessImage        Blob Storage
   |                |                  queue              job                queue              job              (container
   |                |                    |                 |                   |                 |                 "images")
   |                |                    |                 |                   |                 |                    |
   |--1 POST------->|                    |                 |                   |                 |                    |
   |  /api/images   |                    |                 |                   |                 |                    |
   |                |--2 enqueue-------->|                 |                   |                 |                    |
   |                |   { jobId }        |                 |                   |                 |                    |
   |<-3 202---------|                    |                 |                   |                 |                    |
   |  + jobId       |                    |                 |                   |                 |                    |
   |                |                    |                 |                   |                 |                    |
   |                |                    |--4 KEDA sees -->|                   |                 |                    |
   |                |                    |   1 message,    |                   |                 |                    |
   |                |                    |   starts job    |                   |                 |                    |
   |                |                    |                 |--5 GET Buienradar |                 |                    |
   |                |                    |                 |   (50 stations)   |                 |                    |
   |                |                    |                 |--6 enqueue------->|                 |                    |
   |                |                    |                 |   1 msg / station |                 |                    |
   |                |                    |<-7 delete-------|                   |                 |                    |
   |                |                    |   start msg     |                   |                 |                    |
   |                |                    |                 |                   |                 |                    |
   |                |                    |                 |                   |--8 KEDA sees -->|                    |
   |                |                    |                 |                   |   N messages,   |                    |
   |                |                    |                 |                   |   starts up to  |                    |
   |                |                    |                 |                   |   10 replicas   |                    |
   |                |                    |                 |                   |                 |--9 GET photo---->  |
   |                |                    |                 |                   |                 |   draw text        |
   |                |                    |                 |                   |                 |--10 upload-------->|
   |                |                    |                 |                   |                 |    jobId/stationId |
   |                |                    |                 |                   |                 |         .png       |
   |                |                    |                 |                   |<-11 delete------|                    |
   |                |                    |                 |                   |    image msg    |                    |
   |                |                    |                 |                   |                 |                    |
   |--12 GET------->|                    |                 |                   |                 |                    |
   |  /api/images/  |--13 list blobs with prefix "jobId/" ------------------------------------------------------->|
   |     {jobId}    |<-14 blob names -----------------------------------------------------------------------------|
   |<-15 status + --|                    |                 |                   |                 |                    |
   |   image links  |                    |                 |                   |                 |                    |
```

Step 8 is the fan-out. One message from the API turns into one message per weather station, and Azure runs up to ten copies of the ProcessImage job side by side to work through them. In a typical run this produces around 40 images in roughly two to three minutes.

There is no database. The job id is the blob name prefix, so listing the blobs under `{jobId}/` is what answers the status question: zero blobs means the work has not finished yet, and the blobs that are there are the result.

---

## What is in the repository

| Path | What it is |
|---|---|
| `src/WeatherImages.Api` | The public HTTP API. `POST /api/images` starts a job, `GET /api/images/{jobId}` returns status and links. |
| `src/WeatherImages.Jobs.FetchWeather` | Job 1. Reads the Buienradar feed and enqueues one message per station. |
| `src/WeatherImages.Jobs.ProcessImage` | Job 2. Fetches a photo, draws the weather data on it, uploads it to Blob Storage. Runs many times in parallel. |
| `src/WeatherImages.Shared` | The contract shared by all three: the queue message record, the queue and container names, and the connection string setting. |
| `src/WeatherImages.Api/WeatherImages.Api.http` | API documentation as `.http` requests, with working links against the live endpoint. |
| `infra/main.bicep` | The whole infrastructure: storage account, both queues, the blob container, ACR, managed identity, Log Analytics, the Container App and both Container Apps Jobs. |
| `deploy.ps1` | Publishes with the dotnet CLI, creates the resources from the Bicep template, and deploys the containers with the Azure CLI. |
| `Dockerfile.api`, `Dockerfile.fetchweather`, `Dockerfile.processimage` | One multi-stage Dockerfile per deployable. |

---

## Trying the API

There are three ways, in order of least effort.

**Straight in a browser.** These are plain GET requests, so a browser is enough. The first one returns the JSON for a job that has already finished, the second is one of the images it produced.

```
https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io/api/images/ac626648-67b0-4c40-a68b-8991de53e889
https://stweatherimg707875.blob.core.windows.net/images/ac626648-67b0-4c40-a68b-8991de53e889/6215.png
```

**With curl,** if you want to start a fresh run. The POST returns a `jobId`; give it two to three minutes and then ask for the results.

```bash
curl -X POST https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io/api/images

curl https://ca-weatherimages-api.redbay-e7fc2782.norwayeast.azurecontainerapps.io/api/images/<jobId>
```

**With the `.http` file,** which is the documented form. Open `src/WeatherImages.Api/WeatherImages.Api.http` in Visual Studio, JetBrains Rider, or VS Code with the REST Client extension, and use the *Send Request* link above each block. The `@host` at the top already points at the live endpoint.

One thing worth knowing: `POST /api/images` only accepts POST. Opening that URL in a browser sends a GET and returns 405.

---

## Running it locally

You need the .NET 9 SDK and a storage connection string. The three projects all read it from the `STORAGE_CONNECTION` environment variable.

```powershell
$env:STORAGE_CONNECTION = $(az storage account show-connection-string -n stweatherimg707875 -g rg-weatherimages-dev --query connectionString -o tsv)

dotnet run --project src/WeatherImages.Api
```

The two jobs are console applications, so they run the same way and exit on their own once their queue is empty.

```powershell
dotnet run --project src/WeatherImages.Jobs.FetchWeather
dotnet run --project src/WeatherImages.Jobs.ProcessImage
```

The connection string is never committed. `setenv.ps1` in the repository root contains only the command that fetches it, not the value.

---

## Deploying

```powershell
.\deploy.ps1
```

That one command does everything: it checks that Docker and the Azure CLI are ready, publishes all three projects, creates the resource group, creates the Log Analytics workspace and the Container Apps Environment, creates the container registry and logs in, builds and pushes the three images, and finally runs the Bicep deployment. It prints the API's URL at the end.

To deploy into a different subscription, override the name prefix, because the storage account and registry names have to be globally unique.

```powershell
.\deploy.ps1 -NamePrefix myprefix123
```

Every step checks `$LASTEXITCODE` and stops the script on failure, so a broken step cannot quietly produce a "deployment complete" message with nothing behind it.

---

## Design decisions

**Two queues, not one.** `start-job` carries a single message that means "a new run was requested". `process-image` carries one message per weather station. They are separate because they scale differently: the first job should run once, the second should run many times at once. Keeping them apart lets each job have its own KEDA rule.

**The job id is the blob prefix.** Uploading to `{jobId}/{stationId}.png` means the results endpoint can answer purely by listing blobs, with no database and no extra state to keep in sync. The station **id** is used rather than the station name because several names contain spaces, which would end up percent-encoded in the image URLs.

**Upload first, delete the queue message second.** Azure Storage Queues deliver at least once. If the job crashes after uploading but before deleting, the message becomes visible again and the image is simply written a second time over the same name, which is harmless. Deleting first would risk losing a station's image entirely.

**Two regions.** The storage account, container registry, managed identity and Log Analytics workspace live in `swedencentral`; the Container Apps Environment and all three workloads live in `norwayeast`. The reason is in the limitations below.

---

## Known limitations

**The Container Apps Environment is created by the Azure CLI, not by Bicep.** This is the one place where the infrastructure is not fully declarative, and it is deliberate. In the regions available to this subscription, ARM and Bicep templates create an *express* environment, which does not support Container Apps Jobs — a deployment containing a job fails with `ExpressEnvironmentResourceNotSupported`. There is no template property that controls this, and an express environment cannot be converted afterwards. `deploy.ps1` therefore creates the environment with `az containerapp env create --enable-workload-profiles true` before the Bicep deployment runs, and `main.bicep` references it with the `existing` keyword. The environment is placed in `norwayeast` because that region produced a workload-profiles environment reliably; the same template in `swedencentral` did not.

**Blob access is public.** The container is configured with `publicAccess: 'Blob'` so that the returned links open without a token. This satisfies the requirement that the images are served from Blob Storage over a public API, but it means anyone with a link can read an image. SAS tokens are the intended replacement and both spots are marked with a `TODO` in `main.bicep`.

**The registry uses its admin account.** `adminUserEnabled: true`, and the password is read at deploy time with `listCredentials()` and passed to the Container App as a secret. A managed identity with the `AcrPull` role is already created and assigned in the template, so switching the workloads over to it is a small change, also marked `TODO`.

**The status is derived, not recorded.** `GET /api/images/{jobId}` reports `Pending` whenever it finds zero blobs. It cannot tell the difference between a job that is still running, a job that failed, and a job id that never existed. Recording real status in Table Storage is the fix, and is one of the assignment's optional items.

---

## Assignment requirements

| Requirement | Where |
|---|---|
| Public API that creates fresh images | `POST /api/images` in `src/WeatherImages.Api/Program.cs` |
| Queues so the initial call stays fast | The API only enqueues and returns 202 |
| Blob Storage stores and exposes the images | `infra/main.bicep`, container `images`; upload in `ProcessImage/Program.cs` |
| Queue Storage create, read and delete | `CreateIfNotExistsAsync`, `ReceiveMessageAsync`, `DeleteMessageAsync` in both jobs |
| Buienradar API | `FetchWeather/Program.cs` |
| Public image API | `https://picsum.photos` in `ProcessImage/Program.cs` |
| Public API for fetching generated images | `GET /api/images/{jobId}` |
| `.http` files as documentation with working links | `src/WeatherImages.Api/WeatherImages.Api.http` |
| Bicep template including the queues | `infra/main.bicep` |
| GitHub repository with Hijdra added | this repository |
| `deploy.ps1` doing publish, Bicep and Azure CLI deploy | `deploy.ps1` |
| Multiple queues, one to start and one per image | `start-job` and `process-image` |
| Deployed to Azure with a working endpoint | the live endpoint above |
