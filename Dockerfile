# ----- Layer 1: Build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

#Copy all csproj files firstly in order to watch "layer cache" down there (COPY <my computer> <container>)
COPY src/WeatherImages.Shared/WeatherImages.Shared.csproj src/WeatherImages.Shared/
COPY src/WeatherImages.Api/WeatherImages.Api.csproj src/WeatherImages.Api/
#Run this command while building the image to restore NuGet packages for the project. This will be cached in a layer, so if the csproj files don't change, this step will be skipped in future builds.
RUN dotnet restore src/WeatherImages.Api/WeatherImages.Api.csproj 

#Then copy all source files and build the project
COPY src/ src/
RUN dotnet publish src/WeatherImages.Api/WeatherImages.Api.csproj -c Release -o /app/publish

# ----- Layer 2: RUNTIME
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "WeatherImages.Api.dll"]

