"""Validate JSON manifest files (plugin.json, marketplace.json)."""

import sys
import json
from pathlib import Path
from typing import List, Tuple, Dict, Any

import jsonschema
from rich.console import Console
from rich.table import Table

console = Console()


def validate_json_file(json_path: Path, schema_path: Path) -> Tuple[bool, List[str]]:
    """
    Validate a JSON file against a schema.

    Args:
        json_path: Path to JSON file to validate
        schema_path: Path to JSON schema

    Returns:
        Tuple of (is_valid, error_messages)
    """
    errors = []

    try:
        # Load JSON file
        try:
            with open(json_path, "r") as f:
                data = json.load(f)
        except json.JSONDecodeError as e:
            errors.append(f"JSON parsing error: {e}")
            return False, errors

        # Load schema
        with open(schema_path, "r") as f:
            schema = json.load(f)

        # Validate
        try:
            jsonschema.validate(instance=data, schema=schema)
        except jsonschema.ValidationError as e:
            errors.append(f"Schema validation error: {e.message}")
            if e.path:
                errors.append(f"  at path: {'.'.join(str(p) for p in e.path)}")
            if e.schema_path:
                errors.append(f"  schema path: {'.'.join(str(p) for p in e.schema_path)}")
            return False, errors

        return True, []

    except Exception as e:
        errors.append(f"Unexpected error: {e}")
        return False, errors


def validate_marketplace(marketplace_dir: Path) -> Dict[str, Any]:
    """
    Validate marketplace.json file.

    Returns:
        Dictionary with validation results
    """
    results = {"total": 0, "passed": 0, "failed": 0, "details": []}

    marketplace_file = marketplace_dir / ".claude-plugin" / "marketplace.json"
    schema_file = Path("schemas/marketplace-schema.json")

    if not marketplace_file.exists():
        console.print(f"[yellow]No marketplace.json found at {marketplace_file}[/yellow]")
        return results

    results["total"] = 1

    is_valid, errors = validate_json_file(marketplace_file, schema_file)

    result = {
        "file": str(marketplace_file.relative_to(marketplace_dir)),
        "valid": is_valid,
        "errors": errors,
    }
    results["details"].append(result)

    if is_valid:
        results["passed"] += 1
    else:
        results["failed"] += 1

    return results


def validate_plugins(plugins_dir: Path) -> Dict[str, Any]:
    """
    Validate all plugin.json files in plugins directory.

    Returns:
        Dictionary with validation results
    """
    results = {"total": 0, "passed": 0, "failed": 0, "details": []}

    schema_file = Path("schemas/plugin-schema.json")

    # Find all plugin.json files
    plugin_files = list(plugins_dir.glob("*/.claude-plugin/plugin.json"))

    if not plugin_files:
        console.print(f"[yellow]No plugin.json files found in {plugins_dir}[/yellow]")
        return results

    results["total"] = len(plugin_files)

    for plugin_file in sorted(plugin_files):
        is_valid, errors = validate_json_file(plugin_file, schema_file)

        result = {
            "file": str(plugin_file.relative_to(plugins_dir.parent)),
            "valid": is_valid,
            "errors": errors,
        }
        results["details"].append(result)

        if is_valid:
            results["passed"] += 1
        else:
            results["failed"] += 1

    return results


def print_results(results: Dict[str, Any], title: str) -> None:
    """Print validation results in a nice table."""

    # Summary
    console.print(f"\n[bold]{title}[/bold]")
    console.print(f"Total files: {results['total']}")
    console.print(f"[green]Passed: {results['passed']}[/green]")
    console.print(f"[red]Failed: {results['failed']}[/red]")

    # Details table
    if results["details"]:
        table = Table(title="Validation Details")
        table.add_column("File", style="cyan")
        table.add_column("Status", style="bold")
        table.add_column("Errors", style="red")

        for detail in results["details"]:
            status = "[green]✓ PASS[/green]" if detail["valid"] else "[red]✗ FAIL[/red]"
            errors = "\n".join(detail["errors"]) if detail["errors"] else ""
            table.add_row(detail["file"], status, errors)

        console.print(table)


def main() -> int:
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(description="Validate JSON manifest files")
    parser.add_argument("--marketplace", action="store_true", help="Validate marketplace.json")
    parser.add_argument("--plugins", action="store_true", help="Validate plugin.json files")
    parser.add_argument(
        "--all", action="store_true", help="Validate all JSON files (marketplace and plugins)"
    )
    parser.add_argument(
        "--strict", action="store_true", help="Exit with error code if any validation fails"
    )

    args = parser.parse_args()

    # Default to --all if no specific option given
    if not (args.marketplace or args.plugins):
        args.all = True

    total_failed = 0

    # Validate marketplace
    if args.marketplace or args.all:
        results = validate_marketplace(Path("."))
        print_results(results, "Marketplace Validation")
        total_failed += results["failed"]

    # Validate plugins
    if args.plugins or args.all:
        results = validate_plugins(Path("plugins"))
        print_results(results, "Plugin Validation")
        total_failed += results["failed"]

    # Exit code
    if args.strict and total_failed > 0:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
