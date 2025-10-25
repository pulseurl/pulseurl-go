package main

import (
	"log"
	"os"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/pulseurl/pulseurl-go/client"
	"github.com/pulseurl/pulseurl-go/middleware"
)

func main() {
	// Get PulseURL service URL from environment or use default
	serviceURL := os.Getenv("PULSEURL_SERVICE")
	if serviceURL == "" {
		serviceURL = "pulseurl:9090"
	}

	// Get debug logging from environment
	debugLogging := os.Getenv("PULSEURL_DEBUG") == "true"

	// Parse sample rate from environment (default 1.0 = 100%)
	sampleRate := 1.0
	if sampleRateStr := os.Getenv("SAMPLE_RATE"); sampleRateStr != "" {
		if parsed, err := strconv.ParseFloat(sampleRateStr, 64); err == nil {
			sampleRate = parsed
		} else {
			log.Printf("Warning: Invalid SAMPLE_RATE '%s', using default 1.0", sampleRateStr)
		}
	}

	// Parse buffer size from environment (default 1000)
	bufferSize := 1000
	if bufferSizeStr := os.Getenv("BUFFER_SIZE"); bufferSizeStr != "" {
		if parsed, err := strconv.Atoi(bufferSizeStr); err == nil {
			bufferSize = parsed
		} else {
			log.Printf("Warning: Invalid BUFFER_SIZE '%s', using default 1000", bufferSizeStr)
		}
	}

	// Create PulseURL client
	pulseClient, err := client.New(serviceURL, &client.Options{
		BufferSize:   bufferSize,
		SampleRate:   sampleRate,
		DebugLogging: debugLogging,
	})
	if err != nil {
		log.Fatalf("Failed to create PulseURL client: %v", err)
	}
	defer pulseClient.Close()

	// Get service metadata from environment
	serviceName := os.Getenv("SERVICE_NAME")
	if serviceName == "" {
		serviceName = "pulseurl-gin-example"
	}

	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}

	environment := os.Getenv("ENVIRONMENT")
	if environment == "" {
		environment = "production"
	}

	// Create Gin router
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())

	// Add PulseURL middleware
	router.Use(middleware.New(middleware.Config{
		Client: pulseClient,
		Logger: pulseClient.Logger(), // Use same logger as client for consistent log levels
		SkipPaths: []string{
			"/health",
			"/ready",
		},
		CustomLabels: map[string]string{
			"app":         serviceName,
			"environment": environment,
		},
		ServiceName: serviceName,
		Namespace:   namespace,
	}))

	// Health check endpoint (not logged)
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status": "healthy",
		})
	})

	// Readiness check endpoint (not logged)
	router.GET("/ready", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status": "ready",
		})
	})

	// Example API routes (will be logged)
	router.GET("/", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"message":     "Hello from PulseURL Gin example!",
			"service":     serviceName,
			"namespace":   namespace,
			"environment": environment,
		})
	})

	router.GET("/api/users", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"users": []map[string]string{
				{"id": "1", "name": "Alice"},
				{"id": "2", "name": "Bob"},
				{"id": "3", "name": "Charlie"},
			},
		})
	})

	router.GET("/api/users/:id", func(c *gin.Context) {
		id := c.Param("id")
		c.JSON(200, gin.H{
			"id":   id,
			"name": "User " + id,
		})
	})

	router.POST("/api/users", func(c *gin.Context) {
		c.JSON(201, gin.H{
			"message": "User created",
		})
	})

	router.GET("/api/stats", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"requests": 12345,
			"uptime":   "24h",
		})
	})

	// Start server
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Starting %s on :%s", serviceName, port)
	log.Printf("PulseURL service: %s", serviceURL)
	log.Printf("Namespace: %s, Environment: %s", namespace, environment)
	log.Printf("Client config: SampleRate=%.2f, BufferSize=%d, DebugLogging=%v", sampleRate, bufferSize, debugLogging)

	if err := router.Run(":" + port); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
