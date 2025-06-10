#!/bin/bash

echo "🔧 Setting up YAML linting tools..."

# Install yamllint
if command -v yamllint >/dev/null 2>&1; then
    echo "✅ yamllint already installed"
else
    echo "📦 Installing yamllint..."
    sudo apt update && sudo apt install -y yamllint
    echo "✅ yamllint installed"
fi

# Create git hook
if [ -d ".git" ]; then
    echo "📁 Creating git pre-commit hook..."
    mkdir -p .git/hooks
    
    cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
echo "🔍 Running linting checks..."

# YAML check
if command -v yamllint >/dev/null 2>&1; then
    if yamllint -q */compose.yaml; then
        echo "✅ YAML files look good"
    else
        echo "❌ YAML issues found. Run 'make lint' for details."
        exit 1
    fi
fi

echo "✅ All pre-commit checks passed"
EOF
    
    chmod +x .git/hooks/pre-commit
    echo "✅ Git hook installed"
fi

echo ""
echo "✅ YAML linting setup complete!"
echo "   • Run 'make lint' to check YAML and Docker Compose files"
echo "   • Git commits will check YAML files automatically"
