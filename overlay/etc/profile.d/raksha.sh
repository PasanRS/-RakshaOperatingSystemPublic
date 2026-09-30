#!/bin/bash
# Raksha OS — First Boot Environment
# Sourced by login shells

# Ash identity
export ASH_HOME=/var/lib/ash
export ASH_VERSION=0.1.0-alpha
export LLAMA_URL=http://127.0.0.1:8080/v1/chat/completations
export DISPLAY=:0

# PATH
export PATH=$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH

# Bedrock Linux
if [ -f /bedrock/etc/profile.d/bedrock.sh ]; then
    source /bedrock/etc/profile.d/bedrock.sh
fi

# Python venv for Ash tools
if [ -d /opt/ash-core/venv ]; then
    source /opt/ash-core/venv/bin/activate 2>/dev/null
fi

# Welcome message (first boot only)
if [ ! -f /var/lib/ash/.initialized ]; then
    echo ""
    echo "  🜂  Raksha OS — Initializing..."
    echo "  Ash is waking up. Please wait."
    echo ""
fi
