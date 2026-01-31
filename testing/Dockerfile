FROM ubuntu:eoan-20200608

RUN apt-get update && \
    apt-get install -y sudo curl && \
    echo "yadm ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    useradd -m -s /bin/bash yadm

USER yadm
WORKDIR /home/yadm
ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
