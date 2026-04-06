# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-06

First stable release of FauxMQ.

### Added

- TCP AMQP 0-9-1 server for integration tests (listener, framing, handshake, channels)
- Mock/stub API (`stub/3`, `expect/4`) and call history (`calls/1`)
- In-memory queues, exchanges, bindings, and basic publish/consume/get flows
- CI, Credo, Dialyzer, and Hex-oriented packaging

[1.0.0]: https://github.com/aszymanskiit/faux-mq/releases/tag/v1.0.0

## 0.1.0 - Initial release

- Initial implementation of FauxMQ:
    - TCP AMQP 0-9-1 server
    - protocol header and handshake
    - basic channel lifecycle
    - mock/stub API with expectations
    - call history tracking
    - basic frame parser tests and handshake tests
    - CI workflow, Credo, Dialyzer configuration
