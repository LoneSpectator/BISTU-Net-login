FROM busybox:1.38.0-musl

COPY login.sh /usr/local/bin/bistu-login
RUN chmod 0755 /usr/local/bin/bistu-login

ENTRYPOINT ["/usr/local/bin/bistu-login"]
