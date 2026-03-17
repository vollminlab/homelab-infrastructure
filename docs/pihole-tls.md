# Pi-hole TLS Certificate

Each Pi-hole unit uses a self-signed EC certificate for its web interface HTTPS.
The certificate is **not collected by the config scripts** — it is regenerated as needed.

## Generation

Run on each Pi-hole host (adjust CN/SAN for pihole2):

```bash
sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /tmp/pihole1.key -out /tmp/pihole1.crt \
  -days 3650 -nodes \
  -subj "/CN=pihole1.vollminlab.com" \
  -addext "subjectAltName=DNS:pihole1.vollminlab.com"

sudo cat /tmp/pihole1.key /tmp/pihole1.crt | sudo tee /etc/pihole/tls.pem
sudo service pihole-FTL restart
```

For pihole2, replace `pihole1` with `pihole2` throughout.

## Notes

- Curve: P-256 (prime256v1)
- Validity: 10 years (3650 days)
- The combined key+cert PEM lives at `/etc/pihole/tls.pem`
- Private key is not backed up anywhere — regenerate if lost
