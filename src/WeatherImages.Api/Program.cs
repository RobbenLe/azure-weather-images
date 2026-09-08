using Azure.Storage.Queues;

var builder = WebApplication.CreateBuilder(args);

var storageConnection = Environment.GetEnvironmentVariable("STORAGE_CONNECTION");
if (storageConnection == null || storageConnection == "")
{
    throw new InvalidOperationException("STORAGE_CONNECTION is not set. Run: $env:STORAGE_CONNECTION = \"...\"");
}

const string queueName = "start-job";
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

app.UseHttpsRedirection();

var summaries = new[]
{
    "Freezing", "Bracing", "Chilly", "Cool", "Mild", "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
};

app.MapGet("/weatherforecast", () =>
{
    var forecast =  Enumerable.Range(1, 5).Select(index =>
        new WeatherForecast
        (
            DateOnly.FromDateTime(DateTime.Now.AddDays(index)),
            Random.Shared.Next(-20, 55),
            summaries[Random.Shared.Next(summaries.Length)]
        ))
        .ToArray();
    return forecast;
})
.WithName("GetWeatherForecast");



app.MapPost("/api/images", async () =>
{
    //Create jobid
    var jobId = Guid.NewGuid().ToString();
    //Send jobid (message) to queue
    await queueClient.SendMessageAsync(jobId);
    return Results.Accepted($"/api/images/{jobId}", new { jobId }); // 202 + Location header
});

app.Run();

record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
    public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}
