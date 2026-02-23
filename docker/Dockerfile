FROM mcr.microsoft.com/dotnet/aspnet:9.0

# Python fuer BMW/Hyundai-Scripts
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl jq \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir hyundai-kia-connect-api bimmer_connected \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

ENTRYPOINT ["dotnet", "Solarmanager.dll"]
