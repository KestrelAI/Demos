#!/usr/bin/env python3
"""
MSK Cluster Capacity Monitor

Shows broker metrics AND under-replicated partition count.
When UnderReplicatedPartitions > 0, the cluster needs more brokers.
"""

import time
import sys
from datetime import datetime, timedelta

try:
    import boto3
except ImportError:
    print("ERROR: boto3 is required. Install with: pip install boto3")
    sys.exit(1)


def get_cluster_metrics(cloudwatch, cluster_name, num_brokers=2):
    """Fetch cluster-level and broker-level metrics"""
    end_time = datetime.utcnow()
    start_time = end_time - timedelta(minutes=5)
    
    metrics = {
        'under_replicated': 0,  # Default to 0 (no data = no under-replicated partitions)
        'brokers': {}
    }
    
    # Broker-level metrics (including UnderReplicatedPartitions which is per-broker)
    for broker_id in range(1, num_brokers + 1):
        metrics['brokers'][broker_id] = {'cpu': None, 'bytes_in': None}
        
        # UnderReplicatedPartitions - per broker, sum them up
        try:
            resp = cloudwatch.get_metric_statistics(
                Namespace='AWS/Kafka',
                MetricName='UnderReplicatedPartitions',
                Dimensions=[
                    {'Name': 'Cluster Name', 'Value': cluster_name},
                    {'Name': 'Broker ID', 'Value': str(broker_id)}
                ],
                StartTime=start_time, EndTime=end_time,
                Period=60, Statistics=['Maximum']
            )
            if resp['Datapoints']:
                val = int(max(resp['Datapoints'], key=lambda x: x['Timestamp'])['Maximum'])
                if metrics['under_replicated'] is not None:
                    metrics['under_replicated'] += val
                else:
                    metrics['under_replicated'] = val
        except Exception:
            pass
        
        # CPU
        try:
            resp = cloudwatch.get_metric_statistics(
                Namespace='AWS/Kafka', MetricName='CpuUser',
                Dimensions=[
                    {'Name': 'Cluster Name', 'Value': cluster_name},
                    {'Name': 'Broker ID', 'Value': str(broker_id)}
                ],
                StartTime=start_time, EndTime=end_time,
                Period=60, Statistics=['Average']
            )
            if resp['Datapoints']:
                metrics['brokers'][broker_id]['cpu'] = max(resp['Datapoints'], key=lambda x: x['Timestamp'])['Average']
        except Exception:
            pass
        
        # BytesInPerSec
        try:
            resp = cloudwatch.get_metric_statistics(
                Namespace='AWS/Kafka', MetricName='BytesInPerSec',
                Dimensions=[
                    {'Name': 'Cluster Name', 'Value': cluster_name},
                    {'Name': 'Broker ID', 'Value': str(broker_id)}
                ],
                StartTime=start_time, EndTime=end_time,
                Period=60, Statistics=['Average']
            )
            if resp['Datapoints']:
                metrics['brokers'][broker_id]['bytes_in'] = max(resp['Datapoints'], key=lambda x: x['Timestamp'])['Average']
        except Exception:
            pass
    
    return metrics


def render_bar(value, max_val, width=12):
    """Render progress bar"""
    if value is None:
        return '░' * width
    pct = min(value / max_val, 1.0) if max_val > 0 else 0
    filled = int(pct * width)
    return '█' * filled + '░' * (width - filled)


def main():
    if len(sys.argv) < 3:
        print("Usage: broker_monitor.py <cluster_name> <region> [duration] [num_brokers]")
        sys.exit(1)
    
    cluster_name = sys.argv[1]
    region = sys.argv[2]
    duration = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    num_brokers = int(sys.argv[4]) if len(sys.argv) > 4 else 2
    
    cloudwatch = boto3.client('cloudwatch', region_name=region)
    start_time = time.time()
    first_render = True
    
    TABLE_LINES = 6 + num_brokers
    
    # Fixed width for table (60 chars inner content)
    TABLE_WIDTH = 62
    
    print(f"\n  Monitoring: {cluster_name}")
    print(f"  Region: {region} | Brokers: {num_brokers} | Duration: {duration}s")
    print("  ALERT: UnderReplicatedPartitions > 0 triggers incident\n")
    
    try:
        while time.time() - start_time < duration:
            elapsed = int(time.time() - start_time)
            metrics = get_cluster_metrics(cloudwatch, cluster_name, num_brokers)
            
            if not first_render:
                sys.stdout.write(f"\033[{TABLE_LINES}A")
            
            # Header
            print(f"\033[K┌{'─' * TABLE_WIDTH}┐")
            header = f"MSK Cluster Capacity Monitor                Elapsed: {elapsed:>4}s"
            print(f"\033[K│  {header:<{TABLE_WIDTH - 4}}  │")
            print(f"\033[K├{'─' * TABLE_WIDTH}┤")
            
            # Under-replicated partitions - THE KEY METRIC
            ur = metrics['under_replicated']
            ur_str = f"{ur}" if ur is not None else "N/A"
            alert = "🚨 ALERT!" if ur is not None and ur > 0 else "         "
            ur_icon = "⚠️ " if ur is not None and ur > 0 else "   "
            ur_line = f"{ur_icon} Under-Replicated Partitions: {ur_str:<4}              {alert}"
            print(f"\033[K│  {ur_line:<{TABLE_WIDTH - 4}}  │")
            print(f"\033[K├{'─' * TABLE_WIDTH}┤")
            
            # Broker metrics - throughput only
            for bid in range(1, num_brokers + 1):
                bytes_in = metrics['brokers'].get(bid, {}).get('bytes_in')
                
                bytes_mb = bytes_in / (1024 * 1024) if bytes_in else 0
                bytes_bar = render_bar(bytes_mb, 100, 14)  # 100 MB/s max
                bytes_s = f"{bytes_mb:5.1f} MB/s" if bytes_in else "   N/A    "
                
                broker_line = f"Broker {bid}: Throughput [{bytes_bar}] {bytes_s}"
                print(f"\033[K│  {broker_line:<{TABLE_WIDTH - 4}}  │")
            
            print(f"\033[K└{'─' * TABLE_WIDTH}┘")
            sys.stdout.flush()
            
            first_render = False
            time.sleep(5)
            
    except KeyboardInterrupt:
        print("\n\nMonitor stopped.")
    
    print("\nMonitoring complete.")


if __name__ == '__main__':
    main()


