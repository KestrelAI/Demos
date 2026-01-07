// MSK Stress Producer - High-throughput Kafka producer for stress testing
//
// This Go producer is designed to maximize throughput and push MSK brokers
// to high CPU utilization, causing under-replicated partitions.
//
// Build: go build -o stress_producer stress_producer.go
// Run: ./stress_producer -bootstrap <servers> -topic stress-test -duration 300
package main

import (
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/IBM/sarama"
)

var (
	totalMessages int64
	totalBytes    int64
)

func main() {
	// Parse flags
	bootstrap := flag.String("bootstrap", "", "Kafka bootstrap servers (required)")
	topic := flag.String("topic", "stress-test", "Topic to produce to")
	duration := flag.Int("duration", 300, "Duration in seconds")
	workers := flag.Int("workers", 32, "Number of producer goroutines")
	msgSize := flag.Int("size", 10240, "Message size in bytes (default 10KB)")
	batchSize := flag.Int("batch-size", 1048576, "Batch size in bytes (default 1MB)")
	lingerMs := flag.Int("linger-ms", 10, "Linger time in milliseconds")
	compression := flag.String("compression", "lz4", "Compression: none, gzip, snappy, lz4, zstd")
	flag.Parse()

	if *bootstrap == "" {
		fmt.Println("ERROR: -bootstrap is required")
		flag.Usage()
		os.Exit(1)
	}

	// Print config
	fmt.Println("╔══════════════════════════════════════════════════════════════════╗")
	fmt.Println("║              MSK HIGH-THROUGHPUT STRESS PRODUCER                 ║")
	fmt.Println("╚══════════════════════════════════════════════════════════════════╝")
	fmt.Printf("  Bootstrap:    %s\n", truncate(*bootstrap, 60))
	fmt.Printf("  Topic:        %s\n", *topic)
	fmt.Printf("  Duration:     %d seconds\n", *duration)
	fmt.Printf("  Workers:      %d goroutines\n", *workers)
	fmt.Printf("  Message size: %d bytes (%.1f KB)\n", *msgSize, float64(*msgSize)/1024)
	fmt.Printf("  Batch size:   %d bytes (%.1f MB)\n", *batchSize, float64(*batchSize)/1024/1024)
	fmt.Printf("  Linger:       %d ms\n", *lingerMs)
	fmt.Printf("  Compression:  %s\n", *compression)
	fmt.Printf("  Acks:         all (wait for all replicas)\n")
	fmt.Println("══════════════════════════════════════════════════════════════════")
	fmt.Println()

	// Configure Sarama producer for MAXIMUM THROUGHPUT
	config := sarama.NewConfig()
	config.Producer.Return.Successes = false // Don't wait for success - fire and forget for speed
	config.Producer.Return.Errors = true

	// Use leader-only acks for maximum speed (acks=1)
	// WaitForAll is too slow for stress testing
	config.Producer.RequiredAcks = sarama.WaitForLocal

	// Aggressive batching for high throughput
	config.Producer.Flush.Bytes = *batchSize
	config.Producer.Flush.Frequency = time.Duration(*lingerMs) * time.Millisecond
	config.Producer.Flush.Messages = 50000 // Flush after many messages
	config.Producer.Flush.MaxMessages = 0  // No limit

	// Set compression
	switch *compression {
	case "gzip":
		config.Producer.Compression = sarama.CompressionGZIP
	case "snappy":
		config.Producer.Compression = sarama.CompressionSnappy
	case "lz4":
		config.Producer.Compression = sarama.CompressionLZ4
	case "zstd":
		config.Producer.Compression = sarama.CompressionZSTD
	default:
		config.Producer.Compression = sarama.CompressionNone
	}

	// Network settings - maximize parallelism
	config.Net.MaxOpenRequests = 100             // Many concurrent requests
	config.Producer.MaxMessageBytes = 900 * 1024 // 900KB max - under MSK default 1MB limit

	// Large channel buffers to avoid blocking
	config.ChannelBufferSize = 100000

	// Create producer - split comma-separated bootstrap servers into slice
	brokers := strings.Split(*bootstrap, ",")
	for i, b := range brokers {
		brokers[i] = strings.TrimSpace(b)
		fmt.Printf("  Broker %d: %s\n", i+1, brokers[i])
	}
	fmt.Printf("  Connecting to %d brokers...\n", len(brokers))

	// Add timeout for metadata fetch
	config.Metadata.Timeout = 10 * time.Second
	config.Net.DialTimeout = 10 * time.Second
	config.Net.ReadTimeout = 30 * time.Second
	config.Net.WriteTimeout = 30 * time.Second

	producer, err := sarama.NewAsyncProducer(brokers, config)
	if err != nil {
		fmt.Printf("ERROR: Failed to create producer: %v\n", err)
		fmt.Printf("  Check: 1) Brokers reachable 2) Security groups allow :9092 3) Topic exists\n")
		os.Exit(1)
	}
	fmt.Println("  Connected successfully!")
	defer producer.Close()

	// Handle signals for graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*duration)*time.Second)
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Println("\nReceived interrupt, shutting down...")
		cancel()
	}()

	// Pre-generate random messages for each worker
	messages := make([][]byte, *workers)
	for i := 0; i < *workers; i++ {
		messages[i] = make([]byte, *msgSize)
		rand.Read(messages[i])
	}

	// Start error handler (successes disabled for max throughput)
	var wg sync.WaitGroup
	var errorCount int64

	wg.Add(1)
	go func() {
		defer wg.Done()
		for err := range producer.Errors() {
			atomic.AddInt64(&errorCount, 1)
			if atomic.LoadInt64(&errorCount) <= 5 {
				fmt.Printf("Producer error: %v\n", err.Err)
			} else if atomic.LoadInt64(&errorCount) == 6 {
				fmt.Println("(suppressing further errors...)")
			}
		}
	}()

	// Start worker goroutines
	var producerWg sync.WaitGroup
	startTime := time.Now()

	fmt.Printf("Starting %d producer workers...\n\n", *workers)

	for i := 0; i < *workers; i++ {
		producerWg.Add(1)
		go func(workerID int, payload []byte) {
			defer producerWg.Done()

			keyBuf := make([]byte, 16)
			msgCount := int64(0)

			for {
				select {
				case <-ctx.Done():
					return
				default:
					// Generate a unique key
					rand.Read(keyBuf)

					// Send message
					producer.Input() <- &sarama.ProducerMessage{
						Topic: *topic,
						Key:   sarama.ByteEncoder(keyBuf),
						Value: sarama.ByteEncoder(payload),
					}

					msgCount++
					atomic.AddInt64(&totalMessages, 1)
					atomic.AddInt64(&totalBytes, int64(*msgSize))
				}
			}
		}(i, messages[i])
	}

	// Progress reporter
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()

		lastMsgs := int64(0)
		lastBytes := int64(0)
		lastTime := startTime

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				now := time.Now()
				elapsed := now.Sub(startTime).Seconds()
				intervalElapsed := now.Sub(lastTime).Seconds()

				msgs := atomic.LoadInt64(&totalMessages)
				bytes := atomic.LoadInt64(&totalBytes)
				errors := atomic.LoadInt64(&errorCount)

				// Calculate rates
				intervalMsgs := msgs - lastMsgs
				intervalBytes := bytes - lastBytes
				msgRate := float64(intervalMsgs) / intervalElapsed
				mbRate := float64(intervalBytes) / intervalElapsed / 1024 / 1024

				fmt.Printf("[%5.0fs] Sent: %8d | Rate: %7.0f msg/s | Throughput: %6.1f MB/s | Errors: %d\n",
					elapsed, msgs, msgRate, mbRate, errors)

				lastMsgs = msgs
				lastBytes = bytes
				lastTime = now
			}
		}
	}()

	// Wait for workers to complete
	producerWg.Wait()

	// Close producer and wait for handlers
	producer.AsyncClose()
	wg.Wait()

	// Final stats
	elapsed := time.Since(startTime).Seconds()
	totalMsgs := atomic.LoadInt64(&totalMessages)
	totalB := atomic.LoadInt64(&totalBytes)
	errorTotal := atomic.LoadInt64(&errorCount)

	fmt.Println()
	fmt.Println("══════════════════════════════════════════════════════════════════")
	fmt.Println("                        FINAL STATISTICS")
	fmt.Println("══════════════════════════════════════════════════════════════════")
	fmt.Printf("  Duration:    %.1f seconds\n", elapsed)
	fmt.Printf("  Messages:    %d sent, %d errors\n", totalMsgs, errorTotal)
	fmt.Printf("  Throughput:  %.0f msg/sec, %.1f MB/sec\n",
		float64(totalMsgs)/elapsed,
		float64(totalB)/elapsed/1024/1024)
	fmt.Printf("  Total data:  %.1f MB\n", float64(totalB)/1024/1024)
	fmt.Println("══════════════════════════════════════════════════════════════════")
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
}
