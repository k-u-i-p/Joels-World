FROM node:20-slim

WORKDIR /app

# Copy package configurations
COPY package*.json ./

# Install production dependencies
# Since we moved sharp to dependencies, it will be installed here
RUN npm ci --only=production

# Copy the rest of the application
COPY . .

# Expose the port Cloud Run uses
EXPOSE 8080

# Start the application
CMD ["npm", "run", "server"]
