# Contributing to IT-Stack POSTGRESQL

Thank you for contributing to this module!

Please read the organization-level contribution guidelines first:  
https://github.com/it-stack-dev/.github/blob/main/CONTRIBUTING.md

## Module-Specific Notes

- This is **Module 03** in the IT-Stack platform
- All changes must preserve the 6-lab testing progression
- Lab 03-01 (Standalone) must always work without external dependencies
- Test with make test-lab-01 before submitting a PR

## Development Setup

```bash
git clone https://github.com/it-stack-dev/it-stack-postgresql.git
cd it-stack-postgresql
make install
make test
```

## Submitting Changes

1. Branch from develop: git checkout -b feature/your-feature develop
2. Make your changes
3. Run make test-lab-01 to verify standalone still works
4. Open a PR targeting develop
