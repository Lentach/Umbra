# Stage 1: Build Flutter web app
FROM ghcr.io/cirruslabs/flutter:latest AS build

WORKDIR /app

# Copy dependency files first for better layer caching
COPY pubspec.* ./
COPY third_party ./third_party
RUN flutter pub get

# Copy source code
COPY . .

# Build for web with BASE_URL and version metadata from build args
ARG BASE_URL=http://localhost:3000
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=
RUN flutter build web --release \
    --dart-define=BASE_URL=${BASE_URL} \
    --dart-define=GIT_COMMIT=${GIT_COMMIT} \
    --dart-define=BUILD_TIME=${BUILD_TIME} && \
    flutter pub cache clean --force

# Stage 2: Serve with nginx
FROM nginx:alpine

COPY --from=build /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
