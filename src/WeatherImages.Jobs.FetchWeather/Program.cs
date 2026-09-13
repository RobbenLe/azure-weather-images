using System.Net.Http.Json;
using System.Text.Json;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using WeatherImages.Shared;

// ── 1. I check the connection string ───────────────────────────────────────────────────
var connection = Setting.StorageConnection;

//const string containerName = StorageNames.ImagesContainer;
const string queueName = StorageNames.queueName;

// ── 2. I create 2 Queue client: 1 for start job and 1 for process image queue ────────────────────────────────────────────────────────
var startQueue = new QueueClient(connection, queueName);
await startQueue.CreateIfNotExistsAsync();

var processQueue =  new QueueClient(connection, StorageNames.ProcessImageQueue);
await processQueue.CreateIfNotExistsAsync();

// -- 3. Received message ────────────────────────────────────────────────────
var receivedMessage = await startQueue.ReceiveMessageAsync(
    visibilityTimeout: TimeSpan.FromMinutes(2)
);

if (receivedMessage.Value is null)
{
    Console.WriteLine("Queue is empty, nothing to do.");
    return;
}

// -- 4. jobId come from the message ─────────────────────────────
var jobId = receivedMessage.Value.MessageText;
Console.WriteLine($"Got job {jobId}");

// -- 3. I call Buienradar API and check how many Station is available ─────────────────────────────────────────
using var httpClient = new HttpClient();
               
            
var response_from_buienradar = await httpClient.GetFromJsonAsync<BuienradarFeed>("https://data.buienradar.nl/2.0/feed/json"); //Get => Read Body => Parse Json return Object to BuienradarFeed (which is defined below)
var stations = response_from_buienradar?.Actual?.StationMeasurements;

if (stations is null || stations.Count == 0)
{
    Console.WriteLine("No station data found from Buienradar API.");
    return;
}

Console.WriteLine($"Got {stations.Count} stations from Buienradar API.");

// --4. Fan out every station own one message
foreach (var s in stations)
{
    var message = new ProcessImageMessage(
        JobId: jobId,
        StationId: s.StationId,
        StationName: s.StationName,
        Region: s.Regio,
        Temperature: s.Temperature,
        WeatherDescription: s.WeatherDescription
    );
    await processQueue.SendMessageAsync(JsonSerializer.Serialize(message));
}

Console.WriteLine($"Queue {stations.Count} image jobs");


// --5. After processQueue receive message and process.StartQueue delete that message
await startQueue.DeleteMessageAsync(receivedMessage.Value.MessageId, receivedMessage.Value.PopReceipt);
Console.WriteLine("Message deleted from start queue. Job completed.");



// Model receive Json from Buienradar API
public record BuienradarFeed(ActualSection? Actual);
public record ActualSection(List<StationMeasurement>? StationMeasurements);
public record StationMeasurement(
     int     StationId,
    string  StationName,
    string? Regio,
    double? Temperature,
    string? WeatherDescription
);

