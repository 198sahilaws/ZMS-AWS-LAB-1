output "key_name" {
  description = "Name of the EC2 key pair."
  value       = aws_key_pair.this.key_name
}

output "key_pair_id" {
  description = "ID of the EC2 key pair."
  value       = aws_key_pair.this.key_pair_id
}

output "private_key_path" {
  description = "Local filesystem path to the generated private key .pem file."
  value       = local_sensitive_file.private_key.filename
}

output "private_key_pem" {
  description = "PEM-encoded private key material."
  value       = tls_private_key.this.private_key_pem
  sensitive   = true
}

output "public_key_openssh" {
  description = "OpenSSH-formatted public key."
  value       = tls_private_key.this.public_key_openssh
}
