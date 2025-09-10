import os
import shutil
import subprocess

# Function to download datasets from Kaggle
def download_datasets():
    datasets = [
        'username/dataset1',  # Replace with actual Kaggle dataset paths
        'username/dataset2',
        'username/dataset3'
    ]
    
    for dataset in datasets:
        subprocess.run(['kaggle', 'datasets', 'download', dataset])
        unzip_datasets(dataset)

# Function to unzip downloaded datasets
def unzip_datasets(dataset):
    zip_file = f"{dataset.split('/')[-1]}.zip"
    if os.path.exists(zip_file):
        shutil.unpack_archive(zip_file)
        os.remove(zip_file)

# Function to organize datasets into categories
def organize_datasets():
    categories = ['fresh', 'light_damage', 'moderate_damage', 'severe_damage']
    for category in categories:
        os.makedirs(category, exist_ok=True)
        # Logic to move files into respective category folders
        # This part needs to be implemented based on specific criteria

if __name__ == "__main__":
    download_datasets()
    organize_datasets()