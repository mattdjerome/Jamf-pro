import pandas as pd
from collections import Counter
import sys

if len(sys.argv) < 3:
    print("Usage: python script.py <csv_file_path> <column_name>")
    sys.exit(1)

csv_file_path = sys.argv[1]
column_name = sys.argv[2]

# Load the CSV file
df = pd.read_csv(csv_file_path)

# Extract the specified column and drop NaN values
apps_series = df[column_name].dropna()

# Count each app occurrence by treating each line as a separate app
app_counter = Counter()
for entry in apps_series:
    apps = entry.split('\n')
    for app in apps:
        app = app.strip()
        if app:
            app_counter[app] += 1

# Convert the counter to a DataFrame
app_counts_df = pd.DataFrame(app_counter.items(), columns=['App', 'Count'])

# Save the result to a CSV file
app_counts_df.to_csv("app_counts.csv", index=False)

print("App counts saved to app_counts.csv")