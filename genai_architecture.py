from diagrams import Diagram, Cluster, Edge
from diagrams.onprem.vcs import Github, Gitlab
from diagrams.onprem.ci import Jenkins
from diagrams.onprem.container import Docker
from diagrams.aws.compute import EC2, EC2AutoScaling
from diagrams.aws.network import ELB
from diagrams.k8s.compute import Pod, Deployment
from diagrams.k8s.infra import Master, Node
from diagrams.k8s.network import Service
from diagrams.onprem.network import Internet
from diagrams.generic.compute import Rack

with Diagram("GenAI Ops Pipeline Architecture", show=False, filename="genai_architecture", outformat="jpg"):
    
    with Cluster("Developer"):
        developer = Internet("User/Developer")
    
    with Cluster("GitLab CI/CD"):
        gitlab = Gitlab("GitLab Repo")
        ci_cd = Gitlab("CI/CD Pipeline")
        registry = Docker("Container Registry")
        
        developer >> gitlab
        gitlab >> ci_cd
        ci_cd >> registry
    
    with Cluster("AWS Cloud (Free Tier)"):
        
        with Cluster("Auto Scaling Group"):
            asg = EC2AutoScaling("Auto Scaling")
            
            with Cluster("EC2 Instance"):
                ec2 = EC2("t2.micro (Free Tier)")
                
                with Cluster("Self-Managed Kubernetes"):
                    master = Master("K8s Master")
                    node1 = Node("K8s Worker 1")
                    node2 = Node("K8s Worker 2")
                    
                    with Cluster("Application Pods"):
                        deploy = Deployment("Deployment")
                        pod1 = Pod("GenAI App Pod 1")
                        pod2 = Pod("GenAI App Pod 2")
                        svc = Service("Service")
                        
                        deploy >> pod1
                        deploy >> pod2
                        svc >> pod1
                        svc >> pod2
                    
                    master >> node1
                    master >> node2
                    node1 >> pod1
                    node2 >> pod2
        
        lb = ELB("Load Balancer")
        
        lb >> asg
        asg >> ec2
        
    registry >> ec2
    developer >> lb 