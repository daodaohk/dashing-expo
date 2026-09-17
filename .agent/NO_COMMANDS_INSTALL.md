# Install the Dashing Account-Onboarding Update

This update adds the Dashing welcome screen, account creation and sign-in, adult-only profile completion, private country and city collection, session restoration, and the **Sign out** button in the **You** tab.

## Before you start

1. Close Expo Go and any editor that has the Dashing project open.
2. In Finder on Mac or File Explorer on Windows, find your `dashing-expo` project folder.
3. Make a backup: copy the entire `dashing-expo` folder, then rename the copy to something like `dashing-expo backup`.
4. Keep your existing `.env` file. This update does not include one and must not replace it.

## Add the update files

1. Download the ZIP file and double-click it to unzip it.
2. Open the unzipped `dashing-onboarding-update` folder in Finder or File Explorer.
3. Open a second Finder/File Explorer window showing your existing `dashing-expo` folder.
4. Drag the included `src` folder into the existing `dashing-expo` folder. When asked, choose **Merge** or **Replace** so the updated files are used.
5. Drag the included `.agent` folder into the existing `dashing-expo` folder. Choose **Merge** if asked.
6. Drag the included `App.tsx` file into the top level of `dashing-expo`. Choose **Replace** when asked.

Do not drag any files into `.env`, `node_modules`, or `.expo`. Those items are deliberately not included in this update.

## Save it to GitHub with GitHub Desktop

1. Open **GitHub Desktop** and select the `dashing-expo` repository.
2. Click the **Changes** tab. You should see `App.tsx` and the updated files under `src` and `.agent`.
3. Review the file list. Do not include `.env`, `node_modules`, or `.expo` if they appear for any reason.
4. Enter a summary such as `Add account onboarding flow`.
5. Click **Commit to main**.
6. Click **Push origin** at the top of GitHub Desktop.

## After installation

Open the project in your normal Expo workflow. The first screen should now show **Create account** and **Sign in**. A newly created account must complete profile name, username, date of birth, country, and city before it can enter the app. People under 18 are shown guidance and are not allowed through. Existing signed-in people with incomplete profiles are sent to profile completion.
