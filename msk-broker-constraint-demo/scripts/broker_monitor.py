#!/usr/bin/env python3
"""
MSK Broker Resource Monitor - Live ASCII visualization of broker metrics
"""

import boto3
import time
import sys
import os
from datetime import datetime, timedelta

def get_broker_metrics(cloudwatch, cluster_name, region):
    """Fetch CPU and Memory metrics for all brokers"""
    end_time = datetime.utcnow()
    start_time = end_time - timedelta(minutes=5)
    
    brokers = {}
    
    # Get metrics for brokers 1, 2, 3
    for broker_id in [1, 2, 3]:
        brokers[broker_id] = {'cpu': None, 'memory': None}
        
        # CPU metric
        try:
            cpu_response = cloudwatch.get_metric_statistics(
                Namespace='AWS/Kafka',
                MetricName='CpuUser',
                Dimensions=[
                    {'Name': 'Cluster Name', 'Value': cluster_name},
                    {'Name': 'Broker ID', 'Value': str(broker_id)}
                ],
                StartTime=start_time,
                EndTime=end_time,
                Period=60,
                Statistics=['Average']
            )
            if cpu_response['Datapoints']:
                latest = max(cpu_response['Datapoints'], key=lambda x: x['Timestamp'])
                brokers[broker_id]['cpu'] = latest['Average']
        except Exception:
            pass
        
        # Memory metric (MemoryUsed is in bytes, we need percentage)
        try:
            mem_response = cloudwatch.get_metric_statistics(
                Namespace='AWS/Kafka',
                MetricName='MemoryUsed',
                Dimensions=[
                    {'Name': 'Cluster Name', 'Value': cluster_name},
                    {'Name': 'Broker ID', 'Value': str(broker_id)}
                ],
                StartTime=start_time,
                EndTime=end_time,
                Period=60,
                Statistics=['Average']
            )
            if mem_response['Datapoints']:
                latest = max(mem_response['Datapoints'], key=lambda x: x['Timestamp'])
                # t3.small has ~2GB RAM, convert bytes to percentage
                memory_bytes = latest['Average']
                memory_pct = (memory_bytes / (2 * 1024 * 1024 * 1024)) * 100
                brokers[broker_id]['memory'] = min(memory_pct, 100)
        except Exception:
            pass
    
    return brokers

def render_bar(value, width=16):
    """Render a progress bar"""
    if value is None:
        return '░' * width
    filled = int((value / 100) * width)
    return '█' * filled + '░' * (width - filled)

def render_display(brokers, elapsed_seconds):
    """Render the ASCII display"""
    lines = []
    lines.append("")
    lines.append(f"┌─────────────────────────────────────────────────────────────────┐")
    lines.append(f"│  MSK Broker Metrics (Updated every 5s)       Elapsed: {elapsed_seconds:>4}s   │")
    lines.append(f"├─────────────────────────────────────────────────────────────────┤")
    
    for broker_id in [1, 2, 3]:
        cpu = brokers[broker_id]['cpu']
        mem = brokers[broker_id]['memory']
        
        cpu_bar = render_bar(cpu)
        mem_bar = render_bar(mem)
        
        cpu_str = f"{cpu:5.1f}%" if cpu is not None else "  N/A "
        mem_str = f"{mem:5.1f}%" if mem is not None else "  N/A "
        
        # Warning indicator
        warning = ""
        if cpu is not None and cpu > 80:
            warning = " ⚠️"
        elif mem is not None and mem > 90:
            warning = " ⚠️"
        
        lines.append(f"│ Broker {broker_id}:  CPU {cpu_bar} {cpu_str}  Mem {mem_bar} {mem_str}{warning:<3}│")
    
    lines.append(f"└─────────────────────────────────────────────────────────────────┘")
    lines.append("")
    
    return '\n'.join(lines)

def clear_lines(n):
    """Move cursor up and clear lines"""
    for _ in range(n):
        sys.stdout.write('\033[F')  # Move cursor up
        sys.stdout.write('\033[K')  # Clear line

def main():
    if len(sys.argv) < 3:
        print("Usage: broker_monitor.py <cluster_name> <region> [duration_seconds]")
        sys.exit(1)
    
    cluster_name = sys.argv[1]
    region = sys.argv[2]
    duration = int(sys.argv[3]) if len(sys.argv) > 3 else 600
    
    cloudwatch = boto3.client('cloudwatch', region_name=region)
    
    start_time = time.time()
    first_render = True
    last_display_lines = 0
    
    print(f"\n🔍 Monitoring MSK cluster: {cluster_name}")
    print(f"   Region: {region}")
    print(f"   Duration: {duration}s")
    print("   (Metrics may take 1-2 minutes to appear)")
    
    try:
        while time.time() - start_time < duration:
            elapsed = int(time.time() - start_time)
            brokers = get_broker_metrics(cloudwatch, cluster_name, region)
            display = render_display(brokers, elapsed)
            
            # Clear previous display (except on first render)
            if not first_render:
                clear_lines(last_display_lines)
            
            print(display)
            last_display_lines = display.count('\n') + 1
            first_render = False
            
            time.sleep(5)
            
    except KeyboardInterrupt:
        print("\n\nMonitor stopped.")

if __name__ == '__main__':
    main()
