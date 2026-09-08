using Azure.Storage.Blobs;
using Azure.Storage.Queues;

// ── 1. Connection string ───────────────────────────────────────────────────
var connection = Environment.GetEnvironmentVariable("STORAGE_CONNECTION")
    ?? throw new InvalidOperationException("STORAGE_CONNECTION is not set. Run: . .\\setenv.ps1");

const string containerName = "images";
const string queueName = "start-job";

// ── 2. Queue client ────────────────────────────────────────────────────────
var queueClient = new QueueClient(connection, queueName);
await queueClient.CreateIfNotExistsAsync();

// ── 3. Received message ────────────────────────────────────────────────────
var receivedMessage = await queueClient.ReceiveMessageAsync();

if (receivedMessage.Value is null)
{
    Console.WriteLine("Queue is empty, nothing to do.");
    return;
}

// ── 4. jobId come from the message ─────────────────────────────
var jobId = receivedMessage.Value.MessageText;
var blobName = $"{jobId}/hello.txt";

Console.WriteLine($"Got job {jobId}");

// ── 5. Write blob down ─────────────────────────────────────────────
var containerClient = new BlobContainerClient(connection, containerName);
await containerClient.CreateIfNotExistsAsync();

var blobClient = containerClient.GetBlobClient(blobName);
await blobClient.UploadAsync(
    BinaryData.FromString($"processed job {jobId}"),
    overwrite: true);

Console.WriteLine($"Wrote {blobClient.Uri}");

// ── 6. Delete Message ─────────────────────────────────────────
await queueClient.DeleteMessageAsync(
    receivedMessage.Value.MessageId,
    receivedMessage.Value.PopReceipt);

Console.WriteLine("Message deleted. Done.");