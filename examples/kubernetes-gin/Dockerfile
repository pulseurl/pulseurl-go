# Multi-stage build for smaller image
FROM golang:1.25-alpine AS builder

WORKDIR /build

# Copy the entire pulseurl-go module from the build context
COPY . ./

# Set working directory to the example
WORKDIR /build/examples/kubernetes-gin

# Download dependencies
RUN go mod download

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /root/

# Copy the binary from builder
COPY --from=builder /build/examples/kubernetes-gin/main .

# Expose port
EXPOSE 8080

# Run the application
CMD ["./main"]
