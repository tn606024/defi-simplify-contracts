# Base fork tests

RPC-dependent Base tests live here and run separately from the default CI suite.
Use a pinned or explicitly documented Base block whenever reproducibility matters.

The workflow requires the `BASE_RPC_URL` GitHub Actions secret and never stores
RPC credentials in the repository.
