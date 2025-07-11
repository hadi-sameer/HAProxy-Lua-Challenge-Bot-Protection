FROM haproxy:2.8-alpine

# Switch to root to install packages
USER root

# Install only essential packages
RUN apk add --no-cache \
    lua5.3 \
    lua5.3-dev \
    gcc \
    musl-dev \
    make

# Create directories
RUN mkdir -p /usr/local/etc/haproxy/lua-scripts \
    /usr/local/etc/haproxy/public \
    /var/lib/haproxy \
    /run/haproxy

# Copy only essential files
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY lua-scripts/ /usr/local/etc/haproxy/lua-scripts/

# Set proper permissions
RUN chown -R haproxy:haproxy /usr/local/etc/haproxy \
    && chown -R haproxy:haproxy /var/lib/haproxy \
    && chown -R haproxy:haproxy /run/haproxy \
    && chmod 755 /var/lib/haproxy \
    && chmod 755 /run/haproxy \
    && chmod -R 755 /usr/local/etc/haproxy/lua-scripts/ \
    && chmod -R 755 /usr/local/etc/haproxy/public/

# Switch back to the default non-root user
USER haproxy

# Expose ports
EXPOSE 80 8404

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg || exit 1

# Start HAProxy
CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg", "-db"]
