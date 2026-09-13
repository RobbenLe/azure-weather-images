//Store names in a single place to avoid typos and make it easier to change them later.
namespace WeatherImages.Shared;

public static class StorageNames
{
    public const string queueName =  "start-job";
    public const string ProcessImageQueue = "process-image";
    public const string ImagesContainer = "images";
}