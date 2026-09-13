using Azure.Storage.Queues;
using WeatherImages.Shared;

var builder = WebApplication.CreateBuilder(args);

var storageConnection = Setting.StorageConnection;

const string queueName = StorageNames.queueName;
var queueClient = new QueueClient(storageConnection, queueName);
queueClient.CreateIfNotExists();


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

app.Run();

