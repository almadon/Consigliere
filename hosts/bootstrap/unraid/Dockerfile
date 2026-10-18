# The reconciler for hosts that cannot run Ansible themselves (Unraid): one image with everything
# reconcile.sh needs, so nothing is installed on the host and nothing is lost when its root
# filesystem (RAM on Unraid) resets. Build context is hosts/bootstrap:
#   docker build -f unraid/Dockerfile -t consigliere-reconcile hosts/bootstrap
#
# docker:29-cli = the Docker CLI + Compose plugin the roles drive through the host's socket. Keep the
# major version in step with the host's Docker daemon.
FROM docker:29-cli

RUN apk add --no-cache bash git openssh-client python3 py3-pip py3-yaml py3-jinja2 py3-cryptography \
        curl jq rsync age coreutils ca-certificates tzdata \
 && python3 -m pip install --no-cache-dir --break-system-packages ansible-core docker \
 && ansible-galaxy collection install -p /usr/share/ansible/collections \
        community.docker community.general ansible.posix \
 && git config --system safe.directory '*'

# The same pinned, checksum-verified sops the Debian hosts use.
COPY install-sops.sh /usr/local/bin/install-sops.sh
RUN bash /usr/local/bin/install-sops.sh

COPY unraid/loop.sh /usr/local/bin/consigliere-loop
RUN chmod 0755 /usr/local/bin/consigliere-loop

ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections
ENTRYPOINT ["/usr/local/bin/consigliere-loop"]
