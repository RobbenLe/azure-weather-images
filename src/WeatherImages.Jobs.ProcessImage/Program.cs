using WeatherImages.Shared;
using Azure.Storage.Queues;
using Azure.Storage.Blobs;
using System.Text.Json;
using ImageEditor;
using Azure.Storage.Blobs.Models;


var connection = Setting.StorageConnection;

var imageQueue = new QueueClient(connection, StorageNames.ProcessImageQueue);
await imageQueue.CreateIfNotExistsAsync();

var blobService = new BlobServiceClient(connection); //Create Blob service
var blobServiceContainer = blobService.GetBlobContainerClient(StorageNames.ImagesContainer); //create BlobContainer name "Image"
await blobServiceContainer.CreateIfNotExistsAsync(); //If blob container does not exist, create it

//Create Http Client to download images from the internet
using var http = new HttpClient();

while(true)
{
    var receivedMessage = await imageQueue.ReceiveMessageAsync(
        visibilityTimeout: TimeSpan.FromMinutes(2)
    ); //Receive message from the queue

    if (receivedMessage.Value is null)
    {
        Console.WriteLine("Queue is empty. Job completed.");
        break;
    }

    var message = JsonSerializer.Deserialize<ProcessImageMessage>(receivedMessage.Value.MessageText);

    if (message == null)
    {
        Console.WriteLine("Message is null, Delete the message from queue");
        await imageQueue.DeleteMessageAsync(receivedMessage.Value.MessageId, receivedMessage.Value.PopReceipt);
        continue;
    }

    Console.WriteLine($"The function is processing the message for station {message.StationName}");

    ///.1.Dowloadf the public image
    var imageBytes = await http.GetByteArrayAsync("https://picsum.photos/800/600");
    using var sourceStream = new MemoryStream(imageBytes);

    ///2.Write the weather data on image
    using var rendered = ImageHelper.AddTextToImage(
        sourceStream,
        (message.StationName, (20,20), 36, "ffffff"),
        ($"{message.Temperature} C", (20, 70),  48, "ffff00"),
        (message.WeatherDescription ?? "unknown", (20, 130), 28, "ffffff"),
        (message.Region ?? "", (20, 170), 24, "ffffff")
    );

    ///3.Store image with data onit to blob storage
    var blobName = $"{message.JobId}/{message.StationId}.png";
    var blob = blobServiceContainer.GetBlobClient(blobName);

    await blob.UploadAsync(rendered, new BlobUploadOptions 
    {
        HttpHeaders = new BlobHttpHeaders { ContentType = "image/png" }
    });

    Console.WriteLine($"Upload {blobName}");

    ///4.Delete the message
    await imageQueue.DeleteMessageAsync(receivedMessage.Value.MessageId, receivedMessage.Value.PopReceipt);
}









