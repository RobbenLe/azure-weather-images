//This file is the CONTRACT between the FetchWeather job and the ProcessImage job. It defines the message that is sent from one to the other.
namespace WeatherImages.Shared;

//This is value inside meeage
public record ProcessImageMessage(
    string JobId,
    int StationId,
    string StationName,
    string? Region,
    double? Temperature,
    string? WeatherDescription
);