//One file -> one way to check -> 3 projects act the same
namespace WeatherImages.Shared;

public static class Setting
{
    public static string StorageConnection
    {
        get
        {
            var value = Environment.GetEnvironmentVariable("STORAGE_CONNECTION");

            if (value == null || value == "" || value == "  ")
            {
                throw new InvalidOperationException("STORAGE_CONNECTION is not set. Run: .\\setenv.ps1");
            }

            return value;
        }
    }
}