using Azure.Storage.Queues;
using WeatherImages.Shared;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using System.Threading;

var builder = WebApplication.CreateBuilder(args);

var storageConnection = Setting.StorageConnection;

const string queueName = StorageNames.queueName;
var queueClient = new QueueClient(storageConnection, queueName);
queueClient.CreateIfNotExists();

var blobService = new BlobServiceClient(storageConnection);
var imagesContainer = blobService.GetBlobContainerClient(StorageNames.ImagesContainer);


// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.MapPost("/api/images", async () =>
{
    //Create jobid
    var jobId = Guid.NewGuid().ToString();
    //Send jobid (message) to queue
    await queueClient.SendMessageAsync(jobId);
    return Results.Accepted($"/api/images/{jobId}", new { jobId }); // 202 + Location header
});

app.MapGet("/api/images/{jobId}", async (string jobId) =>
{
    var images = new List<string>();

    await foreach (var blob in imagesContainer.GetBlobsAsync(
        BlobTraits.None,
        BlobStates.None,
        $"{jobId}/",
        CancellationToken.None))
    {
        images.Add(imagesContainer.GetBlobClient(blob.Name).Uri.ToString());
    }

    var status = images.Count == 0 ? "Pending" : "Ready";

    return Results.Ok(new
    {
        jobId,
        status,
        imageCount = images.Count,
        images
    });
});

app.Run();

