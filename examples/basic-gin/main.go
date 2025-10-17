package main

import (
	"log"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/pulseurl/pulseurl-go/client"
	"github.com/pulseurl/pulseurl-go/middleware"
)

func main() {
	// Get PulseURL service URL from environment or use default
	serviceURL := os.Getenv("PULSEURL_SERVICE")
	if serviceURL == "" {
		serviceURL = "localhost:9090"
	}

	// Create PulseURL client
	pulseClient, err := client.New(serviceURL, &client.Options{
		BufferSize: 1000,
		SampleRate: 1.0, // Log 100% of requests
	})
	if err != nil {
		log.Fatalf("Failed to create PulseURL client: %v", err)
	}
	defer pulseClient.Close()

	// Create Gin router
	router := gin.Default()

	// Add PulseURL middleware
	router.Use(middleware.New(middleware.Config{
		Client: pulseClient,
		SkipPaths: []string{
			"/health",
			"/metrics",
		},
		CustomLabels: map[string]string{
			"app":         "basic-gin-example",
			"environment": "development",
		},
		Namespace: "default",
	}))

	// Health check endpoint (not logged)
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status": "healthy",
		})
	})

	// Example routes (will be logged)
	router.GET("/", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"message": "Hello from PulseURL Gin example!",
		})
	})

	router.GET("/users", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"users": []string{"alice", "bob", "charlie"},
		})
	})

	router.GET("/users/:id", func(c *gin.Context) {
		id := c.Param("id")
		c.JSON(200, gin.H{
			"id":   id,
			"name": "User " + id,
		})
	})

	router.POST("/users", func(c *gin.Context) {
		c.JSON(201, gin.H{
			"message": "User created",
		})
	})

	// Start server
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Starting server on :%s", port)
	log.Printf("PulseURL service: %s", serviceURL)
	log.Printf("Try: curl http://localhost:%s/", port)

	if err := router.Run(":" + port); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
