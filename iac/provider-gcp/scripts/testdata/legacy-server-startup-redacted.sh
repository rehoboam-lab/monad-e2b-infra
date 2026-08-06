#!/bin/bash
# Secret-redacted shape captured from live instance template
# e2b-orch-server-20260806094256549600000001 on 2026-08-07.
# The live script SHA-256 was e2a69102f82223755cd2641f7e0f5068b049ed8a514585a82260cf17c8dd8ec0;
# only the management UUID below is replaced with a deterministic fixture UUID.
/opt/nomad/bin/run-nomad.sh --server --num-servers "3" --consul-token "11111111-1111-1111-1111-111111111111" --nomad-token "01234567-89ab-cdef-0123-456789abcdef"
