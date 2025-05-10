#!/bin/bash
# AWS CloudShell script to delete a VPC and all its associated resources
# This script requires AWS CLI and assumes you have sufficient permissions (root user)

# Set the VPC name to search for
read -p 'Type the VPC name: ' VPC_NAME
echo "Starting deletion process for VPC named '$VPC_NAME'..."

# Find the VPC ID by its Name tag
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[0].VpcId" --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    echo "No VPC found with name '$VPC_NAME'. Exiting."
    exit 1
fi

echo "Found VPC with ID: $VPC_ID"

# Step 1: Delete any NAT Gateways
echo "Deleting NAT Gateways..."
NAT_GATEWAY_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text)
for NAT_GATEWAY_ID in $NAT_GATEWAY_IDS; do
    echo "  Deleting NAT Gateway: $NAT_GATEWAY_ID"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GATEWAY_ID"
done

# Wait for NAT Gateways to be deleted
if [ -n "$NAT_GATEWAY_IDS" ]; then
    echo "  Waiting for NAT Gateways to be deleted..."
    sleep 15
fi

# Step 2: Delete Load Balancers
echo "Deleting Load Balancers..."
LB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text)
for LB_ARN in $LB_ARNS; do
    echo "  Deleting Load Balancer: $LB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN"
done

# Wait for Load Balancers to be deleted
if [ -n "$LB_ARNS" ]; then
    echo "  Waiting for Load Balancers to be deleted..."
    sleep 20
fi

# Step 3: Terminate EC2 instances
echo "Terminating EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId" --output text)
if [ -n "$INSTANCE_IDS" ]; then
    echo "  Terminating instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
    
    echo "  Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
fi

# Step 4: Delete Auto Scaling Groups
echo "Deleting Auto Scaling Groups..."
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text)
for ASG_NAME in $ASG_NAMES; do
    # Check if ASG is in our VPC by examining its subnets
    ASG_SUBNETS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query "AutoScalingGroups[0].VPCZoneIdentifier" --output text)
    
    # For each subnet in the ASG, check if it belongs to our VPC
    for SUBNET_ID in $(echo $ASG_SUBNETS | tr ',' ' '); do
        SUBNET_VPC=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query "Subnets[0].VpcId" --output text 2>/dev/null)
        if [ "$SUBNET_VPC" == "$VPC_ID" ]; then
            echo "  Deleting Auto Scaling Group: $ASG_NAME"
            aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete
            break
        fi
    done
done

# Step 5: Delete RDS instances and clusters
echo "Deleting RDS instances..."
RDS_INSTANCES=$(aws rds describe-db-instances --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC_ID'].DBInstanceIdentifier" --output text)
for RDS_INSTANCE in $RDS_INSTANCES; do
    echo "  Deleting RDS instance: $RDS_INSTANCE (with final snapshot)"
    aws rds delete-db-instance --db-instance-identifier "$RDS_INSTANCE" --skip-final-snapshot
done

echo "Deleting RDS clusters..."
RDS_CLUSTERS=$(aws rds describe-db-clusters --query "DBClusters[?VpcId=='$VPC_ID'].DBClusterIdentifier" --output text)
for RDS_CLUSTER in $RDS_CLUSTERS; do
    echo "  Deleting RDS cluster: $RDS_CLUSTER (with final snapshot)"
    aws rds delete-db-cluster --db-cluster-identifier "$RDS_CLUSTER" --skip-final-snapshot
done

# Step 6: Delete ElastiCache clusters
echo "Deleting ElastiCache clusters..."
CACHE_CLUSTERS=$(aws elasticache describe-cache-clusters --query "CacheClusters[].CacheClusterId" --output text)
for CLUSTER in $CACHE_CLUSTERS; do
    # Check if cluster is in our VPC
    CLUSTER_VPC=$(aws elasticache describe-cache-clusters --cache-cluster-id "$CLUSTER" --show-cache-node-info --query "CacheClusters[0].CacheSubnetGroupName" --output text)
    if [ -n "$CLUSTER_VPC" ]; then
        SUBNET_GROUP_VPC=$(aws elasticache describe-cache-subnet-groups --cache-subnet-group-name "$CLUSTER_VPC" --query "CacheSubnetGroups[0].VpcId" --output text 2>/dev/null)
        if [ "$SUBNET_GROUP_VPC" == "$VPC_ID" ]; then
            echo "  Deleting ElastiCache cluster: $CLUSTER"
            aws elasticache delete-cache-cluster --cache-cluster-id "$CLUSTER"
        fi
    fi
done

# Step 7: Delete all ELB security groups
echo "Deleting ELB security groups..."
SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=*elb*" --query "SecurityGroups[].GroupId" --output text)
for SG_ID in $SG_IDS; do
    echo "  Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID"
done

# Step 8: Delete VPC endpoints
echo "Deleting VPC endpoints..."
ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text)
for ENDPOINT_ID in $ENDPOINT_IDS; do
    echo "  Deleting VPC endpoint: $ENDPOINT_ID"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ENDPOINT_ID"
done

# Wait for endpoints to be deleted
if [ -n "$ENDPOINT_IDS" ]; then
    echo "  Waiting for endpoints to be deleted..."
    sleep 5
fi

# Step 9: Delete VPC peering connections
echo "Deleting VPC peering connections..."
PEERING_IDS=$(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text)
PEERING_IDS="$PEERING_IDS $(aws ec2 describe-vpc-peering-connections --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text)"
for PEERING_ID in $PEERING_IDS; do
    if [ -n "$PEERING_ID" ] && [ "$PEERING_ID" != "None" ]; then
        echo "  Deleting VPC peering connection: $PEERING_ID"
        aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PEERING_ID"
    fi
done

# Step 10: Delete Network ACLs (except default)
echo "Deleting Network ACLs..."
NACL_IDS=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text)
for NACL_ID in $NACL_IDS; do
    echo "  Deleting Network ACL: $NACL_ID"
    aws ec2 delete-network-acl --network-acl-id "$NACL_ID"
done

# Step 11: Delete all Security Groups (except default)
echo "Deleting Security Groups..."
SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
for SG_ID in $SG_IDS; do
    echo "  Attempting to delete Security Group: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null || echo "    Could not delete SG: $SG_ID (may have dependencies)"
done

# Step 12: Delete Network Interfaces
echo "Deleting Network Interfaces..."
ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text)
for ENI_ID in $ENI_IDS; do
    echo "  Detaching Network Interface: $ENI_ID"
    ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text)
    if [ "$ATTACHMENT_ID" != "None" ] && [ -n "$ATTACHMENT_ID" ]; then
        aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force
        sleep 2
    fi
    
    echo "  Deleting Network Interface: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID"
done

# Step 13: Delete Internet Gateways
echo "Deleting Internet Gateways..."
IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text)
for IGW_ID in $IGW_IDS; do
    echo "  Detaching Internet Gateway: $IGW_ID"
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    
    echo "  Deleting Internet Gateway: $IGW_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
done

# Step 14: Delete Subnet Route Tables
echo "Deleting Route Tables..."
RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text)
for RT_ID in $RT_IDS; do
    # Disassociate any subnets first
    ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-id "$RT_ID" --query "RouteTables[0].Associations[].RouteTableAssociationId" --output text)
    for ASSOC_ID in $ASSOC_IDS; do
        echo "  Disassociating Route Table: $ASSOC_ID"
        aws ec2 disassociate-route-table --association-id "$ASSOC_ID"
    done
    
    echo "  Deleting Route Table: $RT_ID"
    aws ec2 delete-route-table --route-table-id "$RT_ID"
done

# Step 15: Delete Subnets
echo "Deleting Subnets..."
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text)
for SUBNET_ID in $SUBNET_IDS; do
    echo "  Deleting Subnet: $SUBNET_ID"
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
done

# Step 16: Finally, delete the VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID"

echo "VPC deletion process completed!"
