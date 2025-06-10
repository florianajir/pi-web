# Linting Guide

This project uses yamllint to ensure YAML code quality and catch syntax errors early.

- **yamllint** - YAML validation and formatting

## Setup

Install yamllint once:

```bash
make setup-lint
```

This installs:

- yamllint (via apt)
- Git pre-commit hook for automatic validation

## Usage

### Manual Check

```bash
make lint
```

This checks:

- ✅ YAML syntax in compose files and workflows
- ✅ Docker Compose configuration validation

### Automatic Check

The git pre-commit hook automatically runs yamllint on commit to catch issues early.

## Fixing Issues

### YAML (yamllint)

- Remove trailing spaces
- Use 2-space indentation
- Keep lines under 120 characters
- Fix bracket spacing

## Configuration

- `.yamllint` - YAML formatting rules

The configuration uses sensible defaults optimized for this project.
