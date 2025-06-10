# Linting Guide

This project uses yamllint to ensure YAML code quality and catch syntax errors early.

- **yamllint** - YAML validation and formatting

## Usage

### Manual Check

```bash
make lint
```

This checks:

- ✅ YAML syntax in compose files and workflows
- ✅ Docker Compose configuration validation

## Fixing Issues

### YAML (yamllint)

- Remove trailing spaces
- Use 2-space indentation
- Keep lines under 120 characters
- Fix bracket spacing

## Configuration

- `.yamllint` - YAML formatting rules

The configuration uses sensible defaults optimized for this project.
